# Smoke test for slice 1C (profile, peers, chat, moderation, notifications, admin profile).
# Run it while the server is running (mvn spring-boot:run). It talks to your REAL database:
# - it posts ONE Lobby message "smoke-1c test message" and deletes it again as the System Administrator;
# - it saves Andrea's profile and the facilitator's display name with their CURRENT values (no change);
# - it does NOT change any password (only wrong/too-short attempts, which are refused);
# - Connect is permanent (there is no disconnect), so it only runs if you answer y.
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

$studentPw = Read-Plain "Andrea (25-09041) password"
$student = Login "25-09041" $studentPw
$facil   = Login "ADM-001"  (Read-Plain "Frenzy (ADM-001) password")
$admin   = Login "ADM-002"  (Read-Plain "Charles (ADM-002) password")

Step "ST-08 My Profile"
$me = Call GET "/api/student/profile" $student
"$($me.displayName) ($($me.userId), $($me.email)) interests: $($me.interests -join ', ') | visible: $($me.visibleInMatching)"
"chips offered: $($me.allInterests -join ', ')"
$same = @{ displayName = $me.displayName; bio = $me.bio; interests = @($me.interests); visibleInMatching = $me.visibleInMatching }
$saved = Call PUT "/api/student/profile" $student $same
"saved with the same values: $($saved.displayName) / $($saved.interests -join ', ')"
"bio of 151 characters (expect 400 'Bio must be 150 characters or fewer'):"
Call PUT "/api/student/profile" $student @{ displayName = $me.displayName; bio = ("x" * 151); interests = @($me.interests) } | Out-Null
"no interests (expect 400 'Pick at least one interest.'):"
Call PUT "/api/student/profile" $student @{ displayName = $me.displayName; bio = $me.bio; interests = @() } | Out-Null

Step "Password (nothing is changed)"
"wrong current password (expect 400 'Current password is incorrect.'):"
Call POST "/api/student/profile/password" $student @{ currentPassword = "definitely-wrong"; newPassword = "longenough123" } | Out-Null
"correct current, new too short (expect 400 'Password must be at least 8 characters'):"
Call POST "/api/student/profile/password" $student @{ currentPassword = $studentPw; newPassword = "short" } | Out-Null

Step "ST-04 Peer Matching"
$peers = Call GET "/api/student/peers" $student
"Matches ($(@($peers.matches).Count)):"
@($peers.matches) | ForEach-Object { "  {0,-20} shared {1}: {2}  {3}" -f $_.displayName, $_.sharedCount, ($_.sharedInterests -join ', '), $(if ($_.connected) { "[Connected]" } else { "" }) }
"Connected ($(@($peers.connected).Count)): " + ((@($peers.connected) | ForEach-Object { $_.displayName }) -join ", ")
$candidate = @($peers.matches) | Where-Object { -not $_.connected } | Select-Object -First 1
if ($candidate) {
    $answer = Read-Host "Connect Andrea with $($candidate.displayName)? This is permanent (y/N)"
    if ($answer -eq "y") {
        $c = Call POST "/api/student/peers/$($candidate.studentId)/connect" $student
        "connect: $($c.message) roomId=$($c.roomId)"
        "again (expect 400 'You are already connected with $($candidate.displayName).'):"
        Call POST "/api/student/peers/$($candidate.studentId)/connect" $student | Out-Null
    } else { "skipped" }
} else { "no unconnected match to try" }
"connect with yourself (expect 404):"
Call POST "/api/student/peers/25-09041/connect" $student | Out-Null

Step "ST-05 Chats"
$rooms = @(Call GET "/api/student/chats" $student)
$rooms | ForEach-Object { "  {0,-13} {1,-28} {2}" -f $_.type, $_.title, $(if ($_.locked) { "LOCKED: $($_.lockedMessage)" } elseif ($_.lastMessage) { "last: $($_.lastMessage.senderName): $($_.lastMessage.message)" } else { "" }) }
$lobby = $rooms | Where-Object { $_.type -eq "LOBBY" } | Select-Object -First 1
$locked = $rooms | Where-Object { $_.locked } | Select-Object -First 1
if ($locked) {
    "open locked room $($locked.title) (expect 403 ROOM_ACCESS):"
    Call GET "/api/student/chats/$($locked.roomId)/messages" $student | Out-Null
}
"empty message (expect 400 'Message cannot be empty.'):"
Call POST "/api/student/chats/$($lobby.roomId)/messages" $student @{ message = "   " } | Out-Null
"312 characters (expect 400 'Max 300 characters (312/300).'):"
Call POST "/api/student/chats/$($lobby.roomId)/messages" $student @{ message = ("x" * 312) } | Out-Null
$sent = Call POST "/api/student/chats/$($lobby.roomId)/messages" $student @{ message = "smoke-1c test message" }
"sent id $($sent.id) as '$($sent.senderName)' mine=$($sent.mine) at $($sent.sentAt)"
$page = Call GET "/api/student/chats/$($lobby.roomId)/messages?limit=5" $student
"latest $(@($page.messages).Count) in $($page.title), hasOlder=$($page.hasOlder)"
$poll = Call GET "/api/student/chats/$($lobby.roomId)/messages?after=$($sent.id)" $student
"polling after my message: $(@($poll.messages).Count) new (expect 0 unless someone else is chatting)"

Step "AD-08 Chat Moderation"
"facilitator rooms: " + ((@(Call GET "/api/admin/chats" $facil) | ForEach-Object { $_.title }) -join " | ")
"facilitator opens the Lobby (expect 403):"
Call GET "/api/admin/chats/$($lobby.roomId)/messages" $facil | Out-Null
"facilitator deletes the Lobby message (expect 403):"
Call DELETE "/api/admin/chats/messages/$($sent.id)" $facil | Out-Null
$adminRooms = @(Call GET "/api/admin/chats" $admin)
"system administrator sees $($adminRooms.Count) rooms; Direct rooms among them: $(@($adminRooms | Where-Object { $_.type -eq 'PEER' }).Count) (expect 0)"
"system administrator deletes the smoke message:"
Call DELETE "/api/admin/chats/messages/$($sent.id)" $admin | Out-Null
$after = Call GET "/api/admin/chats/$($lobby.roomId)/messages?limit=100" $admin
"smoke message still there: $(@($after.messages | Where-Object { $_.id -eq $sent.id }).Count) (expect 0)"

Step "ST-09 / AD-13 Notifications"
$n = Call GET "/api/student/notifications" $student
"student: $(@($n.items).Count) shown, $($n.unread) unread"
@($n.items) | Select-Object -First 3 | ForEach-Object { "  [{0}] {1} {2}" -f $_.type, $_.message, $(if ($_.read) { "" } else { "(unread)" }) }
$f = Call GET "/api/admin/notifications" $facil
"facilitator: $(@($f.items).Count) shown, $($f.unread) unread"
"system administrator (expect 403, no notifications tab):"
Call GET "/api/admin/notifications" $admin | Out-Null
"mark a random id read (expect 404):"
Call POST "/api/student/notifications/$([guid]::NewGuid())/read" $student | Out-Null

Step "AD-12 Admin profile"
$fp = Call GET "/api/admin/profile" $facil
"facilitator: $($fp.displayName) $($fp.role) manages: " + ((@($fp.managedOrganizations) | ForEach-Object { $_.name }) -join ", ")
$saved = Call PUT "/api/admin/profile" $facil @{ displayName = $fp.displayName }
"saved with the same display name: $($saved.displayName)"
$ap = Call GET "/api/admin/profile" $admin
"system administrator: $($ap.displayName) $($ap.role) allOrganizations=$($ap.allOrganizations)"
"student opens the admin profile (expect 403):"
Call GET "/api/admin/profile" $student | Out-Null

Write-Host ""
Write-Host "Done. Yellow lines above are expected only where a step says 'expect 400/403/404'." -ForegroundColor Green
