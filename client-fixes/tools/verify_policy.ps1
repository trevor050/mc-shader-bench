$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $moduleRoot
$testOutput = Join-Path $repositoryRoot 'work\gui-policy-check'
New-Item -ItemType Directory -Path $testOutput -Force | Out-Null
& javac -d $testOutput (Join-Path $moduleRoot 'src\main\java\dev\afterglow\clientfixes\QueuePolicy.java') (Join-Path $moduleRoot 'tests\QueuePolicyTest.java')
if ($LASTEXITCODE -ne 0) { throw 'Queue policy verification compilation failed.' }
& java -cp $testOutput dev.afterglow.clientfixes.QueuePolicyTest
if ($LASTEXITCODE -ne 0) { throw 'Queue policy verification failed.' }
