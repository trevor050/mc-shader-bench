"""Audit the native Iris settings menu and five quality profiles without touching the game.

By default this locates Prism's installed Iris and runs its real option/profile parser and
properties preprocessor. Pass --iris-jar and --libraries on another installation.
--source-only is a portable, explicitly weaker source-model check.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

SHADERS = Path(__file__).resolve().parents[1] / 'shaders'
EXPECTED_PROFILES = ('ULTRA', 'HIGH', 'MEDIUM', 'LOW', 'POTATO')
PROFILE_FIELDS = {
    'PERFORMANCE_PROFILE', 'SHADOW_MAP_RES', 'SHADOW_DIST', 'SHADOW_SAMPLES',
    'SSR_STEPS', 'VL_STEPS', 'NETHER_SMOG_STEPS',
    'TAA', 'LIGHT_FIELD', 'VOLUMETRIC_LIGHT', 'WATER_SSR', 'CLOUDS',
}
DISABLED_FAMILIES = ('shadowcomp', 'deferred', 'deferred1', 'composite', 'composite1', 'composite3', 'composite4')


def properties(text: str) -> dict[str, str]:
    result = {}
    for line in re.sub(r'\\\r?\n\s*', ' ', text).splitlines():
        line = line.strip()
        if not line or line.startswith(('#', '!')):
            continue
        if '=' in line:
            key, value = line.split('=', 1)
            result[key.strip()] = value.strip()
    return result


def model_properties(text: str, tier: int) -> dict[str, str]:
    """Portable fallback for this pack's small PERFORMANCE_PROFILE-only property conditions."""
    stack, included = [], True
    result = []
    for line in text.splitlines():
        condition = re.match(r'^\s*#if PERFORMANCE_PROFILE\s*(==|>|>=|<|<=)\s*(\d+)\s*$',line)
        if condition:
            operator, value = condition.groups()
            number = int(value)
            outcome = {'==':tier==number, '>':tier>number, '>=':tier>=number,
                       '<':tier<number, '<=':tier<=number}[operator]
            stack.append((included,outcome))
            included = included and outcome
        elif line.strip() == '#else':
            parent,outcome = stack[-1]
            included = parent and not outcome
        elif line.strip() == '#endif':
            included,_ = stack.pop()
        elif included:
            result.append(line)
    if stack:
        raise ValueError('Unclosed properties conditional')
    return properties('\n'.join(result))


def reachable_sources(root: Path) -> dict[Path, str]:
    queue = list(root.glob('*.[fvc]sh'))
    for world in ('world-1', 'world1'):
        queue.extend((root / world).glob('*.[fvc]sh'))
    sources = {}
    while queue:
        path = queue.pop().resolve()
        if path in sources:
            continue
        text = path.read_text(encoding='utf-8')
        sources[path] = text
        for include in re.findall(r'^\s*#include\s+"([^"]+)"', text, re.M):
            queue.append(root / include.lstrip('/') if include.startswith('/') else path.parent / include)
    return sources


def source_options(sources: dict[Path, str]) -> dict[str, dict]:
    """Mirror the relevant numeric/boolean declaration rules, then compare with Iris when available."""
    references = set()
    for text in sources.values():
        references.update(re.findall(r'^\s*#ifn?def[ \t]+(\w+)[ \t]*$', text, re.M))
    options = {}
    for path, text in sources.items():
        for line in text.splitlines():
            match = re.match(r'^\s*(//)?\s*#define[ \t]+(\w+)(.*)$', line)
            if not match:
                continue
            commented, name, tail = match.groups()
            value, _, comment = tail.partition('//')
            value = value.strip()
            if not value and name in references:
                candidate = {'default': 'false' if commented else 'true', 'values': ['true', 'false'], 'type': 'B'}
            else:
                domain = re.search(r'\[([^\]]+)\]', comment)
                if commented or not re.fullmatch(r'[\w.+-]+', value) or not domain:
                    continue
                values = domain[1].split()
                # Iris StringOption ensures the default participates in the list.
                if value not in values:
                    values.append(value)
                candidate = {'default': value, 'values': values, 'type': 'S'}
            if name in options and candidate != options[name]:
                raise ValueError(f'Ambiguous option {name}: {path}')
            options[name] = candidate
    return options


def iris_options(args, sources: dict[Path, str], temp: Path):
    prism = Path(os.environ.get('APPDATA', str(Path.home()))) / 'PrismLauncher'
    iris = args.iris_jar
    if iris is None:
        candidates = sorted((prism / 'instances/ShaderBench/minecraft/mods').glob('iris-*.jar'))
        iris = candidates[-1] if candidates else None
    libraries = args.libraries or prism / 'libraries'
    if iris is None or not iris.is_file() or not libraries.is_dir():
        raise RuntimeError('Iris or its libraries were not found. Supply --iris-jar/--libraries, or use --source-only.')
    java = shutil.which('java')
    if not java:
        raise RuntimeError('Java is required to run the actual installed Iris parser.')
    dependency_names = ('guava', 'fastutil', 'slf4j-api', 'commons-io')
    jars = [iris]
    for dependency in dependency_names:
        candidates = sorted(p for p in libraries.rglob('*.jar') if p.name.startswith(dependency+'-'))
        if not candidates:
            raise RuntimeError(f'Missing Iris parser dependency: {dependency}')
        jars.append(candidates[-1])
    with zipfile.ZipFile(iris) as archive:
        for name in archive.namelist():
            if name.startswith('META-INF/jars/jcpp-') and name.endswith('.jar'):
                destination = temp / Path(name).name
                destination.write_bytes(archive.read(name))
                jars.append(destination)
    manifest = temp / 'sources.txt'
    manifest.write_text('\n'.join(str(p) for p in sources)+'\n')
    command = [java, '--class-path', os.pathsep.join(str(p) for p in jars),
               str(Path(__file__).with_name('IrisMenuOptions.java')), str(SHADERS), str(manifest), str(temp)]
    run = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if run.returncode:
        raise RuntimeError('Installed Iris parser failed:\n'+run.stderr)
    options, profiles = {}, {}
    for line in run.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) != 4:
            continue
        kind, name, default, values = parts
        if kind in ('B', 'S'):
            options[name] = {'default': default, 'values': values.split(','), 'type': kind}
        elif kind == 'P':
            profiles[name] = {'default_match': default == 'true', 'fields': int(values)}
    tier_properties = {tier: properties((temp/f'properties-{tier}.txt').read_text()) for tier in range(5)}
    return options, profiles, tier_properties, iris.name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iris-jar', type=Path)
    parser.add_argument('--libraries', type=Path)
    parser.add_argument('--source-only', action='store_true')
    parser.add_argument('--report', type=Path, help='Optional JSON evidence file')
    args = parser.parse_args()
    raw_properties = (SHADERS/'shaders.properties').read_text()
    # Iris ShaderProperties reads layouts, profiles, sliders, and feature requirements from
    # original Properties, while program/image/uniform directives use preprocessed Properties.
    props = properties(raw_properties)
    lang = properties((SHADERS/'lang/en_US.lang').read_text())
    sources = reachable_sources(SHADERS)
    model = source_options(sources)
    errors = []
    options, parsed_profiles, tier_properties, engine = model, None, None, 'source model only (not Iris)'
    if not args.source_only:
        with tempfile.TemporaryDirectory(prefix='claudebench-menu-') as directory:
            options, parsed_profiles, tier_properties, engine = iris_options(args, sources, Path(directory))
    screens = {key[7:]: value.split() for key,value in props.items() if key.startswith('screen.') and not key.endswith('.columns')}
    screens[''] = props.get('screen','').split()
    seen, controls, active = set(), set(), set()

    def visit(name: str):
        if name in active:
            errors.append(f'Cycle in menu screens: {name}')
            return
        if name in seen:
            return
        if name not in screens:
            errors.append(f'Missing menu screen: {name}')
            return
        seen.add(name)
        active.add(name)
        if name and (f'screen.{name}' not in lang or f'screen.{name}.comment' not in lang):
            errors.append(f'Missing screen label/tooltip: {name}')
        if len(screens[name]) > 16:
            errors.append(f'Overcrowded menu screen: {name} ({len(screens[name])} cells)')
        if len(screens[name]) != len(set(screens[name])-{'<empty>'}) + screens[name].count('<empty>'):
            errors.append(f'Duplicate element on screen: {name}')
        for entry in screens[name]:
            if entry.startswith('[') and entry.endswith(']'):
                visit(entry[1:-1])
            elif entry not in ('<profile>', '<empty>'):
                if entry == '*':
                    errors.append('Wildcard menu exposes unreviewed developer options')
                    continue
                controls.add(entry)
        active.remove(name)

    visit('')
    if seen != set(screens):
        errors.append(f'Unreachable screens: {sorted(set(screens)-seen)}')
    if screens[''].count('<profile>') != 1:
        errors.append('Root menu needs exactly one explicit profile selector')
    for name in controls | PROFILE_FIELDS:
        if name not in options:
            errors.append(f'Iris cannot parse option: {name}')
            continue
        if name not in model or model[name] != options[name]:
            errors.append(f'Source-model/installed-Iris option mismatch: {name}')
        if name in controls:
            if not lang.get('option.'+name) or not lang.get('option.'+name+'.comment'):
                errors.append(f'Missing option label/tooltip: {name}')
            if len(lang.get('option.'+name,'')) > 32:
                errors.append(f'Overlong option label: {name}')
            # Strip line comments and declarations, then verify a real consumer in reachable shader source.
            consumers = '\n'.join(re.sub(r'//[^\n]*|^\s*#define[^\n]*', '', text, flags=re.M) for text in sources.values())
            if not re.search(r'\b'+re.escape(name)+r'\b', consumers):
                errors.append(f'Option has no shader consumer: {name}')
    for name in props.get('sliders','').split():
        if name not in controls or name not in options or options[name]['type'] != 'S':
            errors.append(f'Invalid/unreachable slider: {name}')
    profiles = {key[8:]: value.split() for key,value in props.items() if key.startswith('profile.')}
    if set(profiles) != set(EXPECTED_PROFILES):
        errors.append('Expected exactly Ultra, High, Medium, Low, and Potato profiles')
    assignments = {}
    for name, entries in profiles.items():
        current = {}
        for entry in entries:
            if '=' in entry:
                key,value = entry.split('=',1)
            else:
                key,value = (entry[1:],'false') if entry.startswith('!') else (entry,'true')
            current[key] = value
        assignments[name] = current
        if set(current) != PROFILE_FIELDS:
            errors.append(f'Profile owns unexpected settings: {name}: {sorted(current)}')
        for option,value in current.items():
            if option not in options or value not in options[option]['values']:
                errors.append(f'Invalid profile value: {name} {option}={value}')
        if not lang.get('profile.'+name):
            errors.append(f'Missing profile label: {name}')
        if parsed_profiles and parsed_profiles.get(name,{}).get('fields') != len(PROFILE_FIELDS):
            errors.append(f'Installed Iris omitted profile fields: {name}')
    for option,value in assignments.get('ULTRA',{}).items():
        if option not in options or options[option]['default'] != value:
            errors.append(f'Ultra differs from shader defaults: {option}')
    if parsed_profiles and [name for name,p in parsed_profiles.items() if p['default_match']] != ['ULTRA']:
        errors.append('Installed Iris does not identify exactly Ultra as the default profile')
    # Native Iris cannot conditionally hide menu controls. Keep universal quick controls at the
    # root and a curated Potato page; document tier dependencies on advanced controls.
    conditional_depth = 0
    for line in raw_properties.splitlines():
        if re.match(r'^\s*#if\b',line):
            conditional_depth += 1
        elif line.strip() == '#endif':
            conditional_depth -= 1
        elif conditional_depth and re.match(r'^\s*(screen(?:\.|=)|sliders=|profile\.|iris.features\.)',line):
            errors.append('Original-only Iris property inside a conditional: '+line.strip())
    tier_menus = {}
    for tier in range(5):
        runtime = tier_properties[tier] if tier_properties else model_properties(raw_properties,tier)
        menus = {key[7:]: value.split() for key,value in props.items()
                 if key.startswith('screen.') and not key.endswith('.columns')}
        menus[''] = props.get('screen','').split()
        reached, available = set(), set()
        queue = ['']
        while queue:
            name = queue.pop()
            if name in reached:
                continue
            if name not in menus:
                errors.append(f'Tier {tier} references missing screen: {name}')
                continue
            reached.add(name)
            for entry in menus[name]:
                if entry.startswith('[') and entry.endswith(']'):
                    queue.append(entry[1:-1])
                elif entry not in ('<profile>','<empty>'):
                    available.add(entry)
        if reached != set(menus):
            errors.append(f'Tier {tier} has unreachable pages: {sorted(set(menus)-reached)}')
        if not available <= set(options):
            errors.append(f'Tier {tier} exposes unparsed options: {sorted(available-set(options))}')
        if tier == 0:
            impossible = {'TAA','LIGHT_FIELD','VOLUMETRIC_LIGHT','WATER_SSR','BLOOM_STRENGTH',
                          'EXPOSURE_KEY','GRADE_VIBRANCE','FIREFLIES','LIGHTNING_GROUND','LAVA_HEAT'}
            root_controls = set(menus[''])
            potato_controls = set(menus.get('POTATO',[]))
            if impossible & (root_controls | potato_controls):
                errors.append(f'Universal/Potato page exposes unsupported controls: {sorted(impossible & (root_controls | potato_controls))}')
            for option in impossible & available:
                if 'Requires Low or higher' not in lang.get('option.'+option+'.comment',''):
                    errors.append(f'Inactive Potato option lacks tier dependency: {option}')
            for option in ('TAA','LIGHT_FIELD','VOLUMETRIC_LIGHT','WATER_SSR'):
                if assignments.get('POTATO',{}).get(option) != 'false':
                    errors.append(f'Potato profile fails to disable {option}')
        tier_menus[tier] = {'pages': len(menus)-1, 'controls': sorted(available)}
    shadow_source = next((text for path,text in sources.items() if path.name == 'shadows.glsl'),'')
    vogel = re.search(r'VOGEL_12\[(\d+)\]',shadow_source)
    if vogel and any(int(v) > int(vogel[1]) for v in options['SHADOW_SAMPLES']['values']):
        errors.append('Shadow sample domain exceeds the available Vogel lookup table')
    if tier_properties:
        for tier,runtime in tier_properties.items():
            images = [key for key in runtime if key.startswith('image.')]
            if tier == 0:
                if images or runtime.get('shadow.enabled') != 'false':
                    errors.append('Potato still allocates the voxel field or requests shadows')
                for dimension in ('','world-1/','world1/'):
                    for family in DISABLED_FAMILIES:
                        if runtime.get(f'program.{dimension}{family}.enabled') != 'false':
                            errors.append(f'Potato leaves expensive program enabled: {dimension}{family}')
            elif len(images) != 3 or runtime.get('shadow.enabled') != 'true':
                errors.append(f'Non-Potato runtime image/shadow contract changed: tier {tier}')
            for preserved in ('customTexture.starmap','customTexture.milkyway','customTexture.cloudNoise',
                              'uniform.float.rainLocal','uniform.float.wetLocal','uniform.vec4.skyClimate',
                              'size.buffer.colortex3','size.buffer.colortex7','size.buffer.colortex8',
                              'size.buffer.colortex9','size.buffer.colortex11'):
                if not runtime.get(preserved):
                    errors.append(f'Runtime property missing: tier {tier} {preserved}')
    report = {'parser': engine, 'sources': len(sources), 'player_options': len(controls),
              'screens': len(screens)-1, 'profiles': assignments, 'default': 'ULTRA',
              'runtime_properties_preprocessed_by_iris': tier_properties is not None,
              'native_layout_policy': 'original properties; static on all tiers',
              'potato_page_controls': screens.get('POTATO',[]),
              'tier_menus': tier_menus, 'errors': errors}
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(report,indent=2)+'\n')
    for error in errors:
        print('FAIL:',error)
    print(f"Menu audit: {len(controls)} controls, {len(screens)-1} pages, {len(profiles)} profiles; parser={engine}; errors={len(errors)}")
    print('Static/parser validation only. In-game menu presentation and rendering need a separate runtime check.')
    return 1 if errors else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print('FAIL:',error,file=sys.stderr)
        sys.exit(1)
