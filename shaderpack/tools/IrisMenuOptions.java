// Read-only verifier using the installed Iris option/profile parser and properties preprocessor.
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;
import java.util.TreeMap;
import net.irisshaders.iris.helpers.StringPair;
import net.irisshaders.iris.shaderpack.include.AbsolutePackPath;
import net.irisshaders.iris.shaderpack.option.OptionAnnotatedSource;
import net.irisshaders.iris.shaderpack.option.OptionSet;
import net.irisshaders.iris.shaderpack.option.ProfileSet;
import net.irisshaders.iris.shaderpack.option.values.MutableOptionValues;
import net.irisshaders.iris.shaderpack.preprocessor.PropertiesPreprocessor;

class IrisMenuOptions {
    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]);
        var annotations = new LinkedHashMap<Path, OptionAnnotatedSource>();
        var references = new HashSet<String>();
        for (String file : Files.readAllLines(Path.of(args[1]))) {
            Path path = Path.of(file);
            var parsed = new OptionAnnotatedSource(Files.readString(path));
            annotations.put(path, parsed);
            references.addAll(parsed.getBooleanDefineReferences().keySet());
        }
        var builder = OptionSet.builder();
        annotations.forEach((path, parsed) -> builder.addAll(parsed.getOptionSet(
            AbsolutePackPath.fromAbsolutePath("/" + root.relativize(path).toString().replace('\\', '/')), references)));
        OptionSet options = builder.build();
        new TreeMap<>(options.getBooleanOptions()).forEach((name, merged) -> {
            var option = merged.getOption();
            System.out.println("B\t" + name + "\t" + option.getDefaultValue() + "\ttrue,false");
        });
        new TreeMap<>(options.getStringOptions()).forEach((name, merged) -> {
            var option = merged.getOption();
            System.out.println("S\t" + name + "\t" + option.getDefaultValue() + "\t" + String.join(",", option.getAllowedValues()));
        });
        String rawProperties = Files.readString(root.resolve("shaders.properties"));
        Properties properties = new Properties();
        properties.load(new java.io.StringReader(PropertiesPreprocessor.preprocessSource(rawProperties,
            java.util.List.of(new StringPair("PERFORMANCE_PROFILE", "4")))));
        var profileTree = new LinkedHashMap<String, java.util.List<String>>();
        for (String line : rawProperties.split("\n")) {
            if (line.startsWith("profile.")) {
                String[] pair = line.split("=", 2);
                var entries = java.util.List.of(pair[1].trim().split("\\s+"));
                for (String entry : entries) {
                    String name = entry.contains("=") ? entry.substring(0, entry.indexOf('=')) : entry.replaceFirst("^!", "");
                    if (!options.getBooleanOptions().containsKey(name) && !options.getStringOptions().containsKey(name)) {
                        throw new IllegalArgumentException("Iris cannot parse profile-owned option: " + name);
                    }
                }
                profileTree.put(pair[0].substring(8), entries);
            }
        }
        ProfileSet profiles = ProfileSet.fromTree(profileTree, options);
        var defaults = new MutableOptionValues(options, Map.of());
        profiles.forEach((name, profile) -> {
            System.out.println("P\t" + name + "\t" + profile.matches(options, defaults) + "\t" + profile.optionValues.size());
        });
        for (int tier = 0; tier <= 4; tier++) {
            String processed = PropertiesPreprocessor.preprocessSource(rawProperties,
                java.util.List.of(new StringPair("PERFORMANCE_PROFILE", Integer.toString(tier))));
            Properties tierProperties = new Properties();
            tierProperties.load(new java.io.StringReader(processed));
            String filename = args[2] + "/properties-" + tier + ".txt";
            Files.writeString(Path.of(filename), processed);
            System.out.println("R\t" + tier + "\t" + tierProperties.getProperty("shadow.enabled") + "\t"
                + tierProperties.stringPropertyNames().stream().filter(n -> n.startsWith("image.")).count());
        }
    }
}
