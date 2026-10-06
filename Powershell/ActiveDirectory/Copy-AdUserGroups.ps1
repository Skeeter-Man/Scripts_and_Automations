[CmdletBinding()]
param (
[Parameter(Mandatory = $true)]
[string]$NewUser,
 
[Parameter(Mandatory = $true)]
[string]$CopyFromUser
)

function Copy-ADUserGroups {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$NewUser,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$CopyFromUser
    )

    try {
        # Retrieve AD details for both users
        $SourceUserObj = Get-ADUser -Identity $CopyFromUser -Properties MemberOf -ErrorAction Stop
        $TargetUserObj = Get-ADUser -Identity $NewUser -Properties MemberOf -ErrorAction Stop

        $PrimaryGroupID = $SourceUserObj.PrimaryGroupID

        # Get direct group DNs for both users
        $SourceGroupDNs = @($SourceUserObj.MemberOf)
        $TargetGroupDNs = @($TargetUserObj.MemberOf)

        if (-not $SourceGroupDNs) {
            Write-Warning "Source user '$CopyFromUser' is not a member of any non-primary groups."
            return
        }

        # Identify groups to add:
        # 1. Exclude source primary group
        # 2. Exclude groups target already belongs to
        $GroupsToAdd = @(
            $SourceGroupDNs |
                Get-ADGroup -Properties PrimaryGroupToken -ErrorAction Stop |
                Where-Object {
                    $_.PrimaryGroupToken -ne $PrimaryGroupID -and
                    $TargetGroupDNs -notcontains $_.DistinguishedName
                }
        )

        # Track results
        $AddedGroups  = @()
        $FailedGroups = @()

        if ($GroupsToAdd.Count -gt 0) {

            Write-Host "`nAdding missing groups to '$NewUser'..." -ForegroundColor Cyan

            foreach ($Group in $GroupsToAdd) {

                try {
                    Add-ADGroupMember `
                        -Identity $Group `
                        -Members $TargetUserObj `
                        -ErrorAction Stop

                    Write-Host " + Added to: $($Group.Name)" -ForegroundColor Green

                    $AddedGroups += $Group.Name
                }
                catch {
                    Write-Warning "Failed to add '$NewUser' to '$($Group.Name)': $($_.Exception.Message)"

                    $FailedGroups += $Group.Name
                }
            }
        }
        else {
            Write-Host "`nNo missing groups to add. Target user already has all matching groups." -ForegroundColor Yellow
        }

        # Refetch both users after changes
        $UpdatedSource = Get-ADUser -Identity $CopyFromUser -Properties MemberOf -ErrorAction Stop
        $UpdatedTarget = Get-ADUser -Identity $NewUser -Properties MemberOf -ErrorAction Stop

        $UpdatedSourceGroups = @($UpdatedSource.MemberOf)
        $UpdatedTargetGroups = @($UpdatedTarget.MemberOf)

        # Build one unique list of groups across both users
        $AllGroupDNs = @(
            $UpdatedSourceGroups
            $UpdatedTargetGroups
        ) | Sort-Object -Unique

        Write-Host "`n================ Group Membership Comparison ================" -ForegroundColor Cyan

        $ComparisonResults = foreach ($GroupDN in $AllGroupDNs) {

            try {
                $GroupObj = Get-ADGroup -Identity $GroupDN -ErrorAction Stop

                $InSource = $UpdatedSourceGroups -contains $GroupDN
                $InTarget = $UpdatedTargetGroups -contains $GroupDN

                [PSCustomObject]@{
                    GroupName    = $GroupObj.Name
                    CopyFromUser = if ($InSource) { "YES" } else { "NO" }
                    NewUser      = if ($InTarget) { "YES" } else { "NO" }
                    Match        = if ($InSource -eq $InTarget) { "MATCH" } else { "MISMATCH" }
                }
            }
            catch {
                Write-Warning "Unable to retrieve group '$GroupDN': $($_.Exception.Message)"
            }
        }

        $ComparisonResults |
            Sort-Object GroupName |
            Format-Table -AutoSize

        # Final summary
        Write-Host "`n================ Summary ================" -ForegroundColor Cyan
        Write-Host "Source User : $CopyFromUser"
        Write-Host "Target User : $NewUser"
        Write-Host "Groups Added: $($AddedGroups.Count)" -ForegroundColor Green
        Write-Host "Groups Failed: $($FailedGroups.Count)" `
            -ForegroundColor $(if ($FailedGroups.Count -gt 0) { "Red" } else { "Green" })

        if ($FailedGroups.Count -gt 0) {
            Write-Host "`nFailed Groups:" -ForegroundColor Red

            foreach ($FailedGroup in $FailedGroups) {
                Write-Host " - $FailedGroup" -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Error "Failed to process group copying: $($_.Exception.Message)"
    }
}
# Actually execute the function
Copy-ADUserGroups -NewUser $NewUser -CopyFromUser $CopyFromUser