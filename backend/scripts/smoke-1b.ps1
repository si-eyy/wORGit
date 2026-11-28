# Smoke test for slice 1B. Run it while the server is running (mvn spring-boot:run).
# It talks to your REAL database: it creates one organization called "Smoke Test Org" and deletes it at the end.
# It asks for the passwords of 25-09041 (student), ADM-001 (facilitator) and ADM-002 (system administrator).
param([string]$Base = "http://localhost:8080")

function Read-Plain([string]$label) {
    $s = Read-Host $label -AsSecureString
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Login([string]$id, [string]$pw) {
    $body = @{ userId = $id; password = $pw } | ConvertTo-Json
    (Invoke-RestMethod -Method Post -Uri "$Base/api/auth/login" -ContentType "application/json" -Body $body).token
}

# Returns the response, or $null after printing the HTTP status and error body (yellow).
function Call([string]$method, [string]$path, [string]$token, $body = $null) {
    $headers = @{ Authorization = "Bearer $token" }
    try {
        if ($null -ne $body) {
            return Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $headers -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 6)
        }
        return Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $headers
    } catch {
        $resp = $_.Exception.Response
        # ErrorDetails holds the body PowerShell already read; the stream is only a fallback.
        $text = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $text = $_.ErrorDetails.Message }
        elseif ($resp) { try { $text = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { } }
        Write-Host "   HTTP $([int]$resp.StatusCode): $text" -ForegroundColor Yellow
        return $null
    }
}

function Step([string]$text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }

$student = Login "25-09041" (Read-Plain "Andrea (25-09041) password")
$facil   = Login "ADM-001"  (Read-Plain "Frenzy (ADM-001) password")
$admin   = Login "ADM-002"  (Read-Plain "Charles (ADM-002) password")

Step "Student: browse, search, filter"
$all = @(Call GET "/api/student/organizations" $student)
"$($all.Count) organizations (expect 25 with the starter list); first: $($all[0].name) [$($all[0].state)]"
"search 'guild': $(@(Call GET '/api/student/organizations?search=guild' $student).Count) result(s)"
"category Technology: $(@(Call GET '/api/student/organizations?category=Technology' $student).Count) result(s) (expect 5)"

Step "Student: join and leave a free organization"
$target = $all | Where-Object { $_.state -eq "JOIN" } | Select-Object -First 1
if ($target) {
    "joining: $($target.name)"
    Call POST "/api/student/organizations/$($target.orgId)/join" $student | Out-Null
    "my organizations: $(@(Call GET '/api/student/organizations/mine' $student).Count)"
    $d = Call GET "/api/student/organizations/$($target.orgId)" $student
    "detail: state=$($d.membership.state) fee=$($d.membership.feeStatus) roomId=$($d.membership.roomId)"
    Call DELETE "/api/student/organizations/$($target.orgId)/membership" $student | Out-Null
    "after leaving, my organizations: $(@(Call GET '/api/student/organizations/mine' $student).Count)"
} else { "no organization in JOIN state; skipped" }

Step "System Administrator: create 'Smoke Test Org' (approval required, fee 100)"
$created = Call POST "/api/admin/organizations" $admin @{
    name = "Smoke Test Org"; category = "Technology"; description = "Temporary organization made by smoke-1b.ps1"
    requiresApproval = $true; membershipFee = 100; contactEmail = "smoke@batstate-u.edu.ph"; contactPhone = $null
    interests = @("Technology"); socialLinks = @(@{ platform = "Facebook"; url = "https://facebook.com/smoke" })
}
if ($created) { $orgId = $created.orgId } else {
    $q = [uri]::EscapeDataString("Smoke Test Org")
    $old = @(Call GET "/api/admin/organizations?search=$q" $admin) | Where-Object { $_.name -eq "Smoke Test Org" } | Select-Object -First 1
    if (-not $old) { Write-Host "Could not create or find the smoke organization; stopping." -ForegroundColor Red; return }
    $orgId = $old.orgId
    "using the one left over from an earlier run: $orgId"
}
$form = Call GET "/api/admin/organizations/$orgId" $admin
"created: $($form.name), fee $($form.membershipFee), interests: $($form.interests -join ','), links: $(@($form.socialLinks).Count), members: $($form.memberCount)"

Step "Student: apply twice (the second must fail with 'already pending')"
Call POST "/api/student/organizations/$orgId/apply" $student | Out-Null
"my applications: " + ((@(Call GET "/api/student/applications" $student) | ForEach-Object { "$($_.organizationName)=$($_.status)" }) -join ", ")
Call POST "/api/student/organizations/$orgId/apply" $student | Out-Null

Step "Facilitator: must NOT see the smoke organization's applications (expect 403)"
Call GET "/api/admin/applications?orgId=$orgId" $facil | Out-Null

Step "System Administrator: approve the application"
$list = Call GET "/api/admin/applications?status=PENDING&orgId=$orgId" $admin
"pending: $($list.pending), items: $(@($list.items).Count)"
Call POST "/api/admin/applications/$(@($list.items)[0].applicationId)/approve" $admin | Out-Null
$d = Call GET "/api/student/organizations/$orgId" $student
"student now: state=$($d.membership.state) fee=$($d.membership.feeStatus)"

Step "Payments: the Unpaid record created by joining, then Mark paid"
$pay = @(Call GET "/api/admin/payments?orgId=$orgId" $admin)
$pay | ForEach-Object { "  {0}  {1}  {2}  paid on: {3}" -f $_.studentName, $_.amount, $_.status, $_.datePaid }
Call POST "/api/admin/payments/$($pay[0].paymentId)/mark-paid" $admin | Out-Null
"after Mark paid: $((@(Call GET "/api/admin/payments?orgId=$orgId" $admin))[0].status)"
"marking again (expect 400 'already marked as paid'):"
Call POST "/api/admin/payments/$($pay[0].paymentId)/mark-paid" $admin | Out-Null

Step "Members list shows the fee status"
Call GET "/api/admin/organizations/$orgId/members" $admin | ForEach-Object { "  {0} ({1}) joined {2} fee {3}" -f $_.fullName, $_.studentId, $_.joinedOn, $_.feeStatus }

Step "Facilitator: sees only its own organizations; the smoke organization is blocked"
"organizations: " + ((@(Call GET "/api/admin/organizations" $facil) | ForEach-Object { $_.name }) -join " | ")
"members of the smoke organization (expect 403):"
Call GET "/api/admin/organizations/$orgId/members" $facil | Out-Null
"facilitator payments visible: $(@(Call GET '/api/admin/payments' $facil).Count) (the smoke payment must not be among them)"

Step "Cleanup: removal impact, then delete the smoke organization"
(Call GET "/api/admin/organizations/$orgId/removal-impact" $admin) | ConvertTo-Json -Compress
Call DELETE "/api/admin/organizations/$orgId" $admin | Out-Null
"smoke organizations left: $(@(Call GET '/api/admin/organizations?search=Smoke' $admin).Count) (expect 0)"
Write-Host ""
Write-Host "Done. Yellow lines above are expected only where a step says 'expect 400/403'." -ForegroundColor Green
