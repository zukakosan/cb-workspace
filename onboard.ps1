# Subscription ID はわかっている前提
$subscriptionId = "42edd95d-ae8d-41c1-ac55-40bf336687b4"

# Cloudbase はお客様テナントに登録されたアプリ登録のアプリケーション ID (クライアント ID )を知っている
$cloudbaseAppRegistrationClientId = "eb1a9ab9-4ad1-46c1-b900-e529d612d4e8"

# サービスプリンシパル(権限付与する実体)の ID は知らないので、アプリケーション ID から持ってくる
$cloudbaseAppSpObjId = $(Get-AzADServicePrincipal -ApplicationId $cloudbaseAppRegistrationClientId).Id

# 複数のロール定義を取得
# アタッチしたいRBACロール定義を取得
$cloudbaseRoleURIs = @("https://cbroledefpublic.blob.core.windows.net/roledefinition/basicRole.json","https://cbroledefpublic.blob.core.windows.net/roledefinition/vmscanRole.json")

# 不要なロールを削除するかどうか
$needlessRoleDeletionInput = Read-Host "Do you want to delete the needless roles? (yes/no)"
$needlessRoleDeletionFlag = $needlessRoleDeletionInput -eq "yes"

# アタッチしたいRBACロール定義の名前を取得
$desiredRoleNames = @()
foreach($cloudbaseRoleURI in $cloudbaseRoleURIs){
	Write-Host "Getting Role Definition from $cloudbaseRoleURI"
	# ロール定義のJSONを取得
	$cloudbaseRoleDefinition = $(curl $cloudbaseRoleURI) | ConvertFrom-Json

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

# 追加で割り当てるべきロールが存在する($missingRoleNamesが$nullではない)場合
# 割り当てるべきRBACロール定義のURIを改めて取得
if ($null -ne $missingRoleNames)
{
	$missingRoleURIs = @()
	$missingRoleDefinitions = @()
	foreach($cloudbaseRoleURI in $cloudbaseRoleURIs){
		$cloudbaseRoleDefinition = $(curl $cloudbaseRoleURI) | ConvertFrom-Json
		
		# cloudbaseRoleDefinitionには、既にアタッチされているロールも含まれる
		# よって$missingRoleNamesに含まれるロールのみを取得する
		if ($missingRoleNames.contains($cloudbaseRoleDefinition.Name)){
			$missingRoleURIs += $cloudbaseRoleURI
			$missingRoleDefinitions += $cloudbaseRoleDefinition
		}
	}
	Write-Host "Missing Role URIs: $missingRoleURIs"

	# assignable scopeのsubscriptionを書き換える処理
	foreach($missingRoleDefinition in $missingRoleDefinitions){
		# assignable scopeのsubscriptionを書き換える処理
		$missingRoleDefinition.AssignableScopes = @("/subscriptions/$subscriptionId")

		# ロール名の保持
		$roleName = $missingRoleDefinition.Name

		# 作成したJSONファイルからカスタムロール定義を作成
		# 既に作成されていた場合はエラーになるため、ロールが存在しない場合のみ作成する
		if(!(Get-AzRoleDefinition -Name $roleName)){
			# jsonファイルの作成
			$cloudbaseRoleFile = "$($missingRoleDefinition.Name).json"

			# 作成したJSONファイルに書き込み
			Set-Content $cloudbaseRoleFile $($missingRoleDefinition | ConvertTo-Json)

			Write-Host "JSON File for $roleName has been created!"
			
			New-AzRoleDefinition -InputFile ./$cloudbaseRoleFile
			# カスタムロールの作成に時間がかかるので、作成したロールが使えるようになるまで待つ
			# カスタムロールがAzure側に反映されるまで時間がかかる場合があるので、ここをループする
			while(!(Get-AzRoleDefinition -Name $roleName)){
				Write-Host "Creating Custom Azure RBAC Role: $roleName ..."
				Start-Sleep -Seconds 3
			}
			Write-Host "Custom Azure RBAC Role: $roleName has been created!"
		}
		else{
			Write-Host "Custom Azure RBAC Role: $roleName has already existed!"
		}
		# ロールの割り当て
		New-AzRoleAssignment -ObjectId $cloudbaseAppSpObjId -RoleDefinitionName $roleName -Scope "/subscriptions/$subscriptionId"
		Write-Host "Custom Azure RBAC Role: $roleName has attached to $cloudbaseAppSpObjId !"
	}
}
else
{
	Write-Host "There is no missing roles to attach."
}

# 剥奪するべきロールが存在する($needlessRoleNamesが$nullではない)場合
if ($null -ne $needlessRoleNames)
{
	# 剥奪するべきロール(組込み・カスタム)の剥奪
	foreach($needlessRoleName in $needlessRoleNames){
		Remove-AzRoleAssignment -ObjectId $cloudbaseAppSpObjId -RoleDefinitionName $needlessRoleName
		
		# ユーザーから不要なカスタムロールの削除確認に対して"yes"の入力があった場合
		# 剥奪完了したロールの削除
		# 削除対象はカスタムロールのみ
		if($needlessRoleDeletionFlag -and (Get-AzRoleDefinition -Name $needlessRoleName).IsCustom)
		{
			# 削除するロールが他のプリンシパルに割り当てられていない場合のみ削除する	
			if(!(Get-AzRoleAssignment | Where-Object {$_.RoleDefinitionName -eq $needlessRoleName})) 
			{
				# -Forceを付けないとユーザーへの確認が求められる
				Remove-AzRoleDefinition -Name $needlessRoleName -Force
				Write-Host "Custom Azure RBAC Role: $needlessRoleName has been deleted!"
			}
			else
			{
				Write-Host "Custom Azure RBAC Role: $needlessRoleName cannot be deleted because it is still in use!"
			}
		}
	}
}
else
{
	Write-Host "There is no needless roles to detach."
}

Get-AzRoleAssignment -ObjectId $cloudbaseAppSpObjId
