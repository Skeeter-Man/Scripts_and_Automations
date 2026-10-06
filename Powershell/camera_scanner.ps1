# Define the subnet base
$subnet = "10.0.0"

# Generate IP addresses from .1 to .254 and test them simultaneously
1..254 | ForEach-Object -Parallel {
    $ip = "$using:subnet.$_"
    $ping = [System.Net.NetworkInformation.Ping]::new()
    
    # Ping with a 500ms timeout to keep it fast
    $reply = $ping.Send($ip, 500) 
    
    if ($reply.Status -eq 'Success') {
        [PSCustomObject]@{
            IPAddress = $ip
            Status    = "Alive"
        }
    }
} -ThrottleLimit 254 | Sort-Object IPAddress