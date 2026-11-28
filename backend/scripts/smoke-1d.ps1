# Smoke test for slice 1D (events, attendance, certificates, achievements, report, dashboards, student summary).
# Run it while the server is running. It talks to your REAL database:
# - it creates "Smoke Test Event" 10 days from today and deletes it at the end;
# - if Andrea (25-09041) is in no organization, it joins her to a free one without approval and leaves at the end;
# - marking attendance and generating a certificate are PERMANENT (an achievement is never taken back, and an
#   event with a certificate cannot be deleted), so that part only runs if you answer y.
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
            $json = $body | ConvertTo-Json -Depth 6
            $r = Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($json))
            return $r
        }
        # Windows PowerShell 5.1 hands a JSON list back as ONE object; assigning it and returning the
        # variable unwraps it, so an empty list really is empty and @(...).Count is right.
        $r = Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $headers
        return $r
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

Step "AD-01 Dashboards"
$d = Call GET "/api/admin/dashboard" $admin
"system administrator: $($d.totals.students) students, $($d.totals.organizations) organizations, $($d.totals.messages) messages, $($d.totals.connections) connections"
"needs attention: $($d.needsAttention.pendingApplications) pending applications, $($d.needsAttention.unpaidFees) unpaid fees, $($d.needsAttention.eventsThisWeek) events this week"
"members per organization (top 3): " + ((@($d.membersPerOrganization) | Select-Object -First 3 | ForEach-Object { "$($_.name)=$($_.members)" }) -join ", ")
$f = Call GET "/api/admin/dashboard" $facil
"facilitator organizations: " + ((@($f.organizations) | ForEach-Object { $_.name }) -join ", ")
if ($f.tiles) { "selected tiles: members $($f.tiles.members), pending $($f.tiles.pendingApplications), unpaid $($f.tiles.unpaidFees), events this week $($f.tiles.eventsThisWeek)" }
"student opens the admin dashboard (expect 403):"
Call GET "/api/admin/dashboard" $student | Out-Null

Step "Pick an organization of Andrea's"
$joinedForSmoke = $null
$mine = @(Call GET "/api/student/organizations/mine" $student)
if ($mine.Count -gt 0) {
    $org = $mine[0]
    "using $($org.name) (Andrea is already a member)"
} else {
    $free = @(Call GET "/api/admin/organizations" $admin) | Where-Object { -not $_.requiresApproval -and [decimal]$_.membershipFee -eq 0 } | Select-Object -First 1
    if (-not $free) { Write-Host "No free organization without approval to join; stopping." -ForegroundColor Red; return }
    Call POST "/api/student/organizations/$($free.orgId)/join" $student | Out-Null
    $joinedForSmoke = $free.orgId
    $org = @{ orgId = $free.orgId; name = $free.name }
    "joined $($free.name) for the test (left again at the end)"
}

if (-not $org.orgId) { Write-Host "Could not determine an organization id; stopping." -ForegroundColor Red; return }

Step "AD-10 Create event (System Administrator)"
"missing title (expect 400 'Title is required.'):"
Call POST "/api/admin/events" $admin @{ orgId = $org.orgId; title = " "; eventDate = (Get-Date).AddDays(10).ToString("yyyy-MM-dd"); description = "" } | Out-Null
$created = Call POST "/api/admin/events" $admin @{ orgId = $org.orgId; title = "Smoke Test Event"; eventDate = (Get-Date).AddDays(10).ToString("yyyy-MM-dd"); description = "Made by smoke-1d.ps1" }
if (-not $created) { Write-Host "Could not create the event; stopping." -ForegroundColor Red; return }
$eventId = $created.eventId
"created $eventId"
"in the events list: $(@(@(Call GET "/api/admin/events?orgId=$($org.orgId)" $admin) | Where-Object { $_.eventId -eq $eventId }).Count) (expect 1)"

Step "AD-11 Participants"
$detail = Call POST "/api/admin/events/$eventId/participants" $admin @{ studentId = "25-09041"; role = "ATTENDEE" }
"participants: " + ((@($detail.participants) | ForEach-Object { "$($_.fullName) [$($_.role)] attended=$($_.attended) certificate=$($_.certificateState)" }) -join "; ")
"canDelete=$($detail.canDelete) until $($detail.deleteUntil)"
"add Andrea again (expect 400 'already a participant'):"
Call POST "/api/admin/events/$eventId/participants" $admin @{ studentId = "25-09041" } | Out-Null
"certificate for Andrea before attendance (expect 422 'has no recorded attendance, so no certificate was created.'):"
Call POST "/api/admin/events/$eventId/certificates/25-09041" $admin | Out-Null
$all = Call POST "/api/admin/events/$eventId/certificates" $admin
"generate for all: created $(@($all.created).Count), not eligible: $($all.notEligible -join ', ')"
"facilitator opens this event (403 unless Frenzy manages $($org.name)):"
Call GET "/api/admin/events/$eventId" $facil | Out-Null

$answer = Read-Host "Mark Andrea attended and generate her certificate? PERMANENT: the event can no longer be deleted (y/N)"
if ($answer -eq "y") {
    $detail = Call PUT "/api/admin/events/$eventId/attendance" $admin @{ attendance = @(@{ studentId = "25-09041"; attended = $true }) }
    "attended now: $(@($detail.participants)[0].attended)"
    $cert = Call POST "/api/admin/events/$eventId/certificates/25-09041" $admin
    "certificate $($cert.certificateId): $($cert.title) / $($cert.studentName) / $($cert.text) / issued $($cert.dateIssued)"
    "back to No (expect 400 'already has a certificate'):"
    Call PUT "/api/admin/events/$eventId/attendance" $admin @{ attendance = @(@{ studentId = "25-09041"; attended = $false }) } | Out-Null
    $own = Call GET "/api/student/certificates/$($cert.certificateId)" $student
    "ST-07 as Andrea: $($own.title), $($own.type)"
    "delete the event (expect 400 'issued certificate would be deleted'):"
    Call DELETE "/api/admin/events/$eventId" $admin | Out-Null
    $keep = $true
} else {
    "skipped; removing Andrea from the event:"
    $detail = Call DELETE "/api/admin/events/$eventId/participants/25-09041" $admin
    "participants left: $(@($detail.participants).Count) (expect 0)"
    $keep = $false
}

Step "ST-01 Dashboard and ST-06 Report (Andrea)"
$sd = Call GET "/api/student/dashboard" $student
"$($sd.displayName): score $($sd.stats.score), participation $(if ($null -eq $sd.stats.participationRate) { '-' } else { "$($sd.stats.participationRate)%" }), orgs $($sd.stats.organizations), peers $($sd.stats.peers), messages $($sd.stats.messages)"
"updates: " + ((@($sd.updates) | ForEach-Object { $_.message }) -join " | ")
if ($sd.nextBadge) { "next badge: $($sd.nextBadge.title), $($sd.nextBadge.progress)" }
"upcoming events: " + ((@($sd.upcomingEvents) | ForEach-Object { "$($_.title) ($($_.organizationName), $($_.eventDate))" }) -join "; ")
$r = Call GET "/api/student/report" $student
"report for $($r.fullName): achievements " + ((@($r.achievements) | ForEach-Object { "$($_.title)=$(if ($_.earned) { $_.dateEarned } else { 'locked' })" }) -join ", ")
"events joined: $(@($r.events).Count), certificates: $(@($r.certificates).Count)"

Step "AD-05 Student Summary"
$found = @(Call GET "/api/admin/students?search=25-09041" $admin)
"system administrator search '25-09041': $($found.Count) result(s)"
$s = Call GET "/api/admin/students/25-09041/summary" $admin
"summary: $($s.fullName) score $($s.stats.score), interests $($s.interests -join ', ')"
"facilitator search page (expect 403, Facilitators use Summary buttons):"
Call GET "/api/admin/students?search=a" $facil | Out-Null
"student opens a summary (expect 403):"
Call GET "/api/admin/students/25-09041/summary" $student | Out-Null

Step "Cleanup"
if (-not $keep) {
    Call DELETE "/api/admin/events/$eventId" $admin | Out-Null
    "events named 'Smoke Test Event' left: $(@(@(Call GET '/api/admin/events' $admin) | Where-Object { $_.eventId -eq $eventId }).Count) (expect 0)"
} else {
    "the event stays because it has a certificate (as you chose)"
}
if ($joinedForSmoke) {
    Call DELETE "/api/student/organizations/$joinedForSmoke/membership" $student | Out-Null
    "Andrea left the organization joined for the test"
}
Write-Host ""
Write-Host "Done. Yellow lines above are expected only where a step says 'expect 400/403/422'." -ForegroundColor Green
