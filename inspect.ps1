$asm = [System.Reflection.Assembly]::LoadFrom("C:\Users\yaaco\.nuget\packages\microsoft.semantickernel.agents.openai\1.73.0-preview\lib\net8.0\Microsoft.SemanticKernel.Agents.OpenAI.dll")
$types = $asm.GetExportedTypes() | Where-Object { $_.Name -like '*Assistant*' -or $_.Name -like '*Thread*' }
foreach ($t in $types) {
    Write-Output "=== $($t.FullName) ==="
    $ctors = $t.GetConstructors()
    foreach ($c in $ctors) {
        $params = ($c.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ', '
        Write-Output "  CTOR($params)"
    }
    $methods = $t.GetMethods([System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::DeclaredOnly)
    foreach ($m in $methods) {
        $params = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ', '
        $static = if ($m.IsStatic) { "static " } else { "" }
        Write-Output "  $static$($m.ReturnType.Name) $($m.Name)($params)"
    }
    Write-Output ""
}
