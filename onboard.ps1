# Subscription ID はわかっている前提
$subscriptionId = "42edd95d-ae8d-41c1-ac55-40bf336687b4"

# サービスプリンシパル(権限付与する実体)のID は Cloudbase 側に共有されている
$cloudbaseAppSpObjId = "22d729db-95de-4fd1-9d8d-dfe8d55e2fec"

# 複数のロール定義を取得
# アタッチしたいRBACロール定義を取得
$cloudbaseRoleURIs = @("https://cbroledefpublic.blob.core.windows.net/roledefinition/basicRole.json","https://cbroledefpublic.blob.core.windows.net/roledefinition/vmscanRole.json")

# アタッチしたいRBACロール定義の名前を取得
$desiredRoleNames = @()
foreach($cloudbaseRoleURI in $cloudbaseRoleURIs){
	Write-Host "Getting Role Definition from $cloudbaseRoleURI"
	# CloudShell の場合 .Content 不要
	$cloudbaseRoleDefinition = $(curl $cloudbaseRoleURI) | ConvertFrom-Json
	
	## CloudShell 以外の場合 .Content が必要
	# $cloudbaseRoleDefinition = $(curl $cloudbaseRoleURI).Content | ConvertFrom-Json 
	$desiredRoleNames += $cloudbaseRoleDefinition.Name
	$desiredRoleURIs += $cloudbaseRoleURI
}
Write-Host "Desired Roles: $desiredRoleNames"

# 今アタッチされているRBACロールを取得
$attachedRoles = Get-AzRoleAssignment -ObjectId $cloudbaseAppSpObjId
$attachedRoleNames = @()
foreach($attachedRole in $attachedRoles){
	$attachedRoleNames += $attachedRole.RoleDefinitionName
}
Write-Host "Attached Roles: $attachedRoleNames"

# 新たに作成するべきRBACロール定義を判別
$missingRoleNames = $desiredRoleNames | Where-Object { $attachedRoleNames -notcontains $_ }
Write-Host "Missing Roles: $missingRoleNames"

# 取り除くべきRBACロール名のリストを取得
$needlessRoleNames = $attachedRoleNames | Where-Object { $desiredRoleNames -notcontains $_ }
Write-Host "Needless Roles: $needlessRoleNames"

# 割り当てるべきRBACロール定義のURIを改めて取得
$missingRoleURIs = @()
$missingRoleDefinitions = @()
foreach($cloudbaseRoleURI in $cloudbaseRoleURIs){
	$cloudbaseRoleDefinition = $(curl $cloudbaseRoleURI) | ConvertFrom-Json
	if ($missingRoleNames.contains($cloudbaseRoleDefinition.Name)){
		$missingRoleURIs += $cloudbaseRoleURI
		$missingRoleDefinitions += $cloudbaseRoleDefinition
	}
}
Write-Host "Missing Role URIs: $missingRoleURIs"
# Write-Host "Missing Role Definitions: $missingRoledDefinitions"

# assignable scopeのsubscriptionを書き換える処理
foreach($missingRoleDefinition in $missingRoleDefinitions){
	# assignable scopeのsubscriptionを書き換える処理
	$missingRoleDefinition.AssignableScopes = @("/subscriptions/$subscriptionId")
	# write-host $missingRoleDefinition.AssignableScopes
	# write-host $missingRoleDefinition | ConvertTo-Json

	# ロール名の保持
	$roleName = $missingRoleDefinition.Name

	# jsonファイルの作成
	$cloudbaseRoleFile = "$($missingRoleDefinition.Name).json"
	write-host "Creating $cloudbaseRoleFile"

	# 作成したJSONファイルに書き込み
	Set-Content $cloudbaseRoleFile $($missingRoleDefinition | ConvertTo-Json)

	# 作成したJSONファイルからカスタムロール定義を作成
	# ※既に作成されていた場合はエラーになるので、エラーハンドリングが必要
	New-AzRoleDefinition -InputFile ./$cloudbaseRoleFile

	
	# カスタムロールの作成に時間がかかるので、作成したロールが使えるようになるまで待つ
	# カスタムロールがAzure側に反映されるまで時間がかかる場合があるので、ここをループする
	while(!(Get-AzRoleDefinition -Name $roleName)){
		Write-Host "Creating Custom Azure RBAC Role: $roleName ..."
		Start-Sleep -Seconds 3
	}
	Write-Host "Custom Azure RBAC Role: $roleName has created!"

	# 作成完了したロールの割り当て
	New-AzRoleAssignment -ObjectId $cloudbaseAppSpObjId -RoleDefinitionName $roleName -Scope "/subscriptions/$subscriptionId"
	Write-Host "Custom Azure RBAC Role: $roleName has attached to $cloudbaseAppSpObjId !"
}

# 剥奪するべきロールの剥奪
foreach($needlessRoleName in $needlessRoleNames){
	Remove-AzRoleAssignment -ObjectId $cloudbaseAppSpObjId -RoleDefinitionName $needlessRoleName
}

Write-Host Get-AzRoleAssignment -ObjectId $cloudbaseAppSpObjId
