#!/usr/bin/env python3

# =========================================================
# FlyingAura Cloudflare Protection Installer
# =========================================================

import os
import sys
import time
import requests
import subprocess

# =========================================================
# COLORS
# =========================================================
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
WHITE = "\033[97m"
RESET = "\033[0m"
BOLD = "\033[1m"

# =========================================================
# CONFIG
# =========================================================
TUTORIAL_URL = "https://www.youtube.com/watch?v=mwRWyDM28TY"

# =========================================================
# ASCII BANNER
# =========================================================
BANNER = f"""{CYAN}

███████╗██╗     ██╗   ██╗██╗███╗   ██╗ ██████╗      █████╗ ██╗   ██╗██████╗  █████╗
██╔════╝██║     ╚██╗ ██╔╝██║████╗  ██║██╔════╝     ██╔══██╗██║   ██║██╔══██╗██╔══██╗
█████╗  ██║      ╚████╔╝ ██║██╔██╗ ██║██║  ███╗    ███████║██║   ██║██████╔╝███████║
██╔══╝  ██║       ╚██╔╝  ██║██║╚██╗██║██║   ██║    ██╔══██║██║   ██║██╔══██╗██╔══██║
██║     ███████╗   ██║   ██║██║ ╚████║╚██████╔╝    ██║  ██║╚██████╔╝██║  ██║██║  ██║
╚═╝     ╚══════╝   ╚═╝   ╚═╝╚═╝  ╚═══╝ ╚═════╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝

                  FlyingAura Protection Installer

{RESET}
"""

# =========================================================
# TERMINAL HELPERS
# =========================================================
def clear():
    os.system("clear")

def pause():
    input(f"\n{YELLOW}Press Enter to continue...{RESET}")

def info(msg):
    print(f"{CYAN}[INFO]{RESET} {msg}")

def success(msg):
    print(f"{GREEN}[SUCCESS]{RESET} {msg}")

def warning(msg):
    print(f"{YELLOW}[WARNING]{RESET} {msg}")

def error(msg):
    print(f"{RED}[ERROR]{RESET} {msg}")

def step(number, title):
    print(f"\n{BOLD}{CYAN}STEP {number}:{RESET} {WHITE}{title}{RESET}\n")

# =========================================================
# RUN COMMAND
# =========================================================
def run_command(command, check=True):

    print(f"{CYAN}[RUNNING]{RESET} {command}\n")

    process = subprocess.run(
        command,
        shell=True,
        text=True,
        capture_output=True
    )

    if process.stdout:
        print(process.stdout)

    if process.stderr:
        print(process.stderr)

    if check and process.returncode != 0:
        error("Command failed.")
        sys.exit(1)

    return process

# =========================================================
# CLOUDFLARE REQUEST
# =========================================================
def cf_request(method, url, api_key, payload=None):

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

    response = requests.request(
        method,
        url,
        headers=headers,
        json=payload
    )

    try:
        return response.json()

    except:
        error("Invalid Cloudflare API response.")
        sys.exit(1)

# =========================================================
# VALIDATE API TOKEN
# =========================================================
def validate_api_key(api_key):

    step(1, "Validating Cloudflare API Token")

    data = cf_request(
        "GET",
        "https://api.cloudflare.com/client/v4/user/tokens/verify",
        api_key
    )

    if not data.get("success"):
        error("Invalid Cloudflare API token.")
        sys.exit(1)

    success("Cloudflare API token validated successfully.")

# =========================================================
# GET SERVER IP
# =========================================================
def get_server_ip():

    step(2, "Detecting Server Public IP")

    try:
        response = requests.get("https://api.ipify.org")

        ip = response.text.strip()

        success(f"Server IP: {ip}")

        return ip

    except:
        error("Failed detecting public IP.")
        sys.exit(1)

# =========================================================
# INSTALL DEPENDENCIES
# =========================================================
def install_dependencies():

    step(3, "Installing Dependencies")

    commands = [

        "sudo apt-get update",

        "sudo apt-get install -y curl jq python3-requests ufw nginx",

        "sudo mkdir -p --mode=0755 /usr/share/keyrings",

        "curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null",

        "echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list",

        "sudo apt-get update",

        "sudo apt-get install -y cloudflared"
    ]

    for cmd in commands:
        run_command(cmd)

    success("Dependencies installed successfully.")

# =========================================================
# EXTRACT TOKEN
# =========================================================
def extract_token(user_input):

    user_input = user_input.strip()

    if "service install" in user_input:
        token = user_input.split("service install")[-1].strip()

    else:
        token = user_input

    return token.replace('"', "").replace("'", "").strip()

# =========================================================
# HANDLE EXISTING CONNECTOR
# =========================================================
def handle_existing_service():

    warning("Existing cloudflared connector detected.\n")

    print("1) Replace Existing Connector")
    print("2) Exit Installer\n")

    choice = input(f"{CYAN}Select an option:{RESET} ").strip()

    if choice == "1":

        run_command(
            "sudo cloudflared service uninstall",
            check=False
        )

        success("Existing connector removed.")

    else:
        sys.exit(0)

# =========================================================
# INSTALL TUNNEL
# =========================================================
def install_tunnel():

    step(4, "Installing Cloudflare Tunnel")

    print(f"{WHITE}Paste your cloudflared install command or tunnel token below.{RESET}\n")

    user_input = input(f"{CYAN}Paste command or token:{RESET} ").strip()

    if not user_input:
        error("Tunnel token cannot be empty.")
        sys.exit(1)

    token = extract_token(user_input)

    process = run_command(
        f"sudo cloudflared service install {token}",
        check=False
    )

    stderr = process.stderr.lower()

    if process.returncode != 0:

        if "already installed" in stderr:

            handle_existing_service()

            process = run_command(
                f"sudo cloudflared service install {token}",
                check=False
            )

            if process.returncode != 0:
                error("Failed reinstalling connector.")
                sys.exit(1)

            success("Cloudflare connector replaced successfully.")
            return

        error("Failed installing cloudflared tunnel.")
        sys.exit(1)

    success("Cloudflare tunnel installed successfully.")

# =========================================================
# ROUTE CONFIRMATION
# =========================================================
def published_route_confirmation(panel_url, domain):

    while True:

        clear()

        print(BANNER)

        step(5, "Published Application Route")

        subdomain = panel_url.replace(f".{domain}", "")

        print(f"{YELLOW}Add a Published Application Route inside Cloudflare Tunnel.{RESET}\n")

        print(f"{CYAN}Tutorial:{RESET} {TUTORIAL_URL}\n")

        print(f"{WHITE}Hostname Section:{RESET}")
        print(f"Subdomain -> {subdomain}")
        print(f"Domain     -> {domain}")
        print("Path       -> Leave Empty\n")

        print(f"{WHITE}Service Section:{RESET}")
        print("Type -> HTTP")
        print("URL  -> 127.0.0.1:8080\n")

        input(f"{YELLOW}Press Enter once completed...{RESET}")

        print("\n1) Yes, I added it")
        print("2) Go Back\n")

        choice = input(f"{CYAN}Select an option:{RESET} ").strip()

        if choice == "1":
            success("Published Application Route confirmed.")
            break

# =========================================================
# FETCH RULESET
# =========================================================
def get_ruleset_id(api_key, zone_id, phase):

    step(6, f"Fetching Ruleset Phase: {phase}")

    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/phases/{phase}/entrypoint"

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

    response = requests.get(url, headers=headers)

    try:
        data = response.json()

    except:
        error("Cloudflare returned invalid JSON.")
        sys.exit(1)

    if response.status_code == 200 and data.get("success"):

        ruleset_id = data["result"]["id"]

        success(f"Ruleset Found")

        return ruleset_id

    error(f"Failed fetching ruleset phase: {phase}")
    sys.exit(1)

# =========================================================
# WIPE RULES
# =========================================================
def wipe_rules(api_key, zone_id, ruleset_id):

    step(7, "Removing Existing Rules")

    data = cf_request(
        "GET",
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/{ruleset_id}",
        api_key
    )

    rules = data["result"].get("rules", [])

    for rule in rules:

        info(f"Deleting: {rule.get('description', 'Unnamed Rule')}")

        cf_request(
            "DELETE",
            f"https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/{ruleset_id}/rules/{rule['id']}",
            api_key
        )

# =========================================================
# CHECK EXISTING NGINX CONFIG
# =========================================================
def check_existing_nginx(panel_url):

    step(8, "Checking Existing NGINX Configurations")

    found_configs = []

    nginx_paths = [
        "/etc/nginx/sites-enabled",
        "/etc/nginx/sites-available"
    ]

    search_terms = [
        panel_url,
        "127.0.0.1:8080",
        "listen 8080",
        "listen 127.0.0.1:8080"
    ]

    for path in nginx_paths:

        if not os.path.exists(path):
            continue

        for file in os.listdir(path):

            full_path = os.path.join(path, file)

            if not os.path.isfile(full_path):
                continue

            try:

                with open(full_path, "r") as f:
                    content = f.read()

                for term in search_terms:

                    if term in content:
                        found_configs.append(full_path)
                        break

            except:
                pass

    if not found_configs:
        success("No conflicting nginx configurations found.")
        return

    warning("Existing nginx configurations detected.\n")

    for cfg in found_configs:
        print(f"{RED}- {cfg}{RESET}")

    print(f"""
{RED}
WARNING:
Existing configurations may conflict with FlyingAura protection.

1) Continue Without Deleting
2) Delete Conflicting Configs (Recommended)
3) Exit Installer
{RESET}
""")

    choice = input(f"{CYAN}Select an option:{RESET} ").strip()

    if choice == "1":
        return

    elif choice == "2":

        for cfg in found_configs:

            try:
                os.remove(cfg)
                success(f"Deleted: {cfg}")

            except:
                error(f"Failed deleting: {cfg}")

        run_command("sudo systemctl reload nginx", check=False)

    else:
        sys.exit(0)

# =========================================================
# DEPLOY NGINX CONFIG
# =========================================================
def deploy_nginx_config(panel_url):

    step(9, "Deploying NGINX Configuration")

    nginx_config = f"""server {{
    listen 127.0.0.1:8080;
    server_name {panel_url};

    root /var/www/pterodactyl/public;

    index index.php index.html index.htm;

    location / {{
        try_files $uri $uri/ /index.php?$query_string;
    }}

    location ~ \\.php$ {{
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }}

    location ~ /\\.ht {{
        deny all;
    }}
}}
"""

    config_path = "/etc/nginx/sites-available/pterodactyl.local.conf"

    with open(config_path, "w") as f:
        f.write(nginx_config)

    enabled_path = "/etc/nginx/sites-enabled/pterodactyl.local.conf"

    if not os.path.exists(enabled_path):

        run_command(
            f"sudo ln -s {config_path} {enabled_path}",
            check=False
        )

    run_command("sudo nginx -t")

    run_command("sudo systemctl restart nginx")

    success("NGINX configuration deployed successfully.")

# =========================================================
# DEPLOY CUSTOM RULES
# =========================================================
def deploy_custom_rules(api_key, zone_id, ruleset_id, server_ip):

    step(10, "Deploying Custom Rules")

    rules = [

        {
            "description": " ᴡʜɪᴛᴇʟɪѕᴛ ꜰʟʏɪɴɢᴀᴜʀᴀ ᴘʀᴏᴛᴇᴄᴛɪᴏɴ",

            "expression": f"(ip.src in {{{server_ip}}})",

            "position": {
                "index": 1
            },

            "action_parameters": {
                "ruleset": "current",

                "phases": [
                    "http_ratelimit",
                    "http_request_firewall_managed",
                    "http_request_sbfm"
                ],

                "products": [
                    "zoneLockdown",
                    "bic",
                    "uaBlock",
                    "hot",
                    "securityLevel",
                    "rateLimit",
                    "waf"
                ]
            },

            "action": "skip"
        },

        {
            "description": "ʙʟᴏᴄᴋ ʀᴇɢɪᴏɴs ᴀɴᴅ ᴇxᴛʀᴀs",

            "expression": r'''(http.user_agent contains "CensysInspect/1.1") or (ip.src.country in {"T1"}) or (ip.src in {162.142.125.0/24 167.94.138.0/24 199.45.154.0/24 199.45.155.0/24 206.168.34.0/24 2602:80d:1000:b0cc:e::/80 2602:80d:1003::/112 2602:80d:1004::/112}) or (http.user_agent contains "CensysInspect") or (http.user_agent contains "ShodanInspect") or (http.user_agent contains "Shodan") or (http.user_agent contains "Censys") or (ip.src in {37.114.50.51}) or (http.user_agent contains "CensysInspect") or (http.user_agent contains "CensysInspect") or (http.user_agent contains "CensysInspect/1.1") or (http.user_agent contains "Censys") or (http.user_agent contains "ZmEu") or (http.user_agent contains "Nikto") or (http.user_agent contains "Nmap") or (http.user_agent contains "sqlmap") or (http.user_agent contains "acunetix") or (http.user_agent contains "netsparker") or (http.user_agent contains "masscan") or (http.user_agent contains "dirbuster") or (http.user_agent contains "fimap") or (http.user_agent contains "AppScan") or (http.user_agent contains "whatweb") or (http.user_agent contains "OpenVAS") or (http.user_agent contains "nessus") or (http.user_agent contains "w3af") or (http.user_agent contains "netcraft") or (http.user_agent contains "jaascois") or (http.user_agent contains "sqlninja") or (http.user_agent contains "pangolin") or (http.user_agent contains "Xenu") or (http.user_agent contains "paros") or (http.user_agent contains "safetydog") or (http.user_agent contains "crawler4j") or (http.user_agent contains "HTTrack") or (http.user_agent contains "libwww-perl") or (http.user_agent contains "python-requests") or (http.user_agent contains "WinHttp") or (http.user_agent contains "Apache-HttpClient") or (http.user_agent contains "httpclient") or (http.user_agent contains "curl") or (http.user_agent contains "wget") or (http.user_agent contains "java") or (http.user_agent contains "Go-http-client") or (http.user_agent contains "axios") or (http.user_agent contains "bot") or (http.user_agent contains "scan") or (http.user_agent contains "spider") or (http.user_agent contains "scraper") or (http.user_agent contains "mj12bot") or (http.user_agent contains "AhrefsBot") or (http.user_agent contains "SemrushBot") or (http.user_agent contains "DotBot") or (http.user_agent contains "PetalBot") or (http.user_agent contains "SeznamBot") or (http.user_agent contains "Gigabot") or (http.user_agent contains "BLEXBot") or (http.user_agent contains "Bytespider") or (http.user_agent contains "Googlebot") or (http.user_agent contains "Googlebot-Image") or (http.user_agent contains "AdsBot-Google") or (http.user_agent contains "Bingbot") or (http.user_agent contains "bingbot") or (http.user_agent contains "DuckDuckBot") or (http.user_agent contains "Baiduspider") or (http.user_agent contains "YandexBot") or (http.user_agent contains "Sogou") or (http.user_agent contains "Facebot") or (http.user_agent contains "facebookexternalhit") or (http.user_agent contains "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)") or (http.user_agent contains "Mozilla/5.0 (Linux; Android 8.0.0; Nexus 5 Build/OPR6.170623.014) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/64.0.3282.137 Mobile Safari/537.36") or (http.user_agent contains "Mozilla/5.0 (compatible; Googlebot-Image/1.0; +http://www.google.com/bot.html)") or (http.user_agent contains "AdsBot-Google (+http://www.google.com/adsbot.html)") or (http.user_agent contains "Mozilla/5.0 (Linux; Android 9; Pixel 3 XL Build/PQ1A.190205.004) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/73.0.3683.90 Mobile Safari/537.36")''',

            "action": "block"
        },

        {
            "description": "ғɪʀᴇᴡᴀʟʟ ᴘʀᴏᴛᴇᴄᴛɪᴏɴ",

            "expression": r'''(cf.verified_bot_category in {"Monitoring & Analytics" "Advertising & Marketing" "Academic Research" "AI Crawler" "Feed Fetcher"}) or (not ip.src.country in {"BT" "IN" "NP" "PK" "LK" "BD"})''',

            "action": "challenge"
        },

        {
            "description": " ᴄᴀᴘᴛᴄʜᴀ ᴘʀᴏᴛᴇᴄᴛɪᴏɴ",

            "expression": "true",

            "action": "managed_challenge"
        }
    ]

    previous_rule_id = None

    for index, rule in enumerate(rules):

        if index != 0:

            rule["position"] = {
                "after": previous_rule_id
            }

        info(f"Deploying: {rule['description']}")

        data = cf_request(
            "POST",
            f"https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/{ruleset_id}/rules",
            api_key,
            rule
        )

        if not data.get("success"):

            error(f"Failed deploying: {rule['description']}")
            sys.exit(1)

        created_rule = data["result"]["rules"][-1]

        previous_rule_id = created_rule["id"]

        success(f"Deployed: {rule['description']}")

        time.sleep(1)

    success("All custom firewall rules deployed successfully.")

# =========================================================
# DEPLOY RATE LIMIT
# =========================================================
def deploy_rate_limit(api_key, zone_id, ruleset_id):

    step(11, "Deploying Rate Limit Protection")

    payload = {

        "description": "ʀᴀᴛᴇʟɪᴍɪᴛɪɴɢ ꜰʟʏɪɴɢᴀᴜʀᴀ ᴘʀᴏᴛᴇᴄᴛɪᴏɴ",

        "expression": '(not cf.bot_management.verified_bot) or (starts_with(http.request.uri.path, "/"))',

        "ratelimit": {

            "characteristics": [
                "cf.colo.id",
                "ip.src"
            ],

            "requests_to_origin": False,

            "requests_per_period": 70,

            "period": 10,

            "mitigation_timeout": 10
        },

        "action": "block"
    }

    data = cf_request(
        "POST",
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/{ruleset_id}/rules",
        api_key,
        payload
    )

    if not data.get("success"):

        error("Failed deploying rate limit.")
        sys.exit(1)

    success("Rate limit protection deployed successfully.")

# =========================================================
# CONFIGURE UFW
# =========================================================
def configure_ufw():

    step(12, "Configuring Firewall")

    warning("""
The installer will:

- Install UFW if missing
- Allow SSH port 22
- Enable UFW
- Remove ALL other allowed ports
- Keep ONLY port 22 open
            
- Telling NO will make the protection very weak!
""")

    confirm = input(f"\n{CYAN}This will delete ALL UFW rules except SSH (22/tcp IPv4 & IPv6). Continue? (y/N): {RESET}").lower()

    if confirm != "y":
        warning("Skipping firewall configuration.")
        return

    run_command("sudo apt-get install -y ufw")

    run_command("sudo ufw --force reset")

    run_command("ufw allow 22/tcp")
    run_command("ufw --force enable")
    run_command("ufw status verbose")

    success("Firewall configured successfully.")

# =========================================================
# INSTALL PROTECTION
# =========================================================
def install_protection():

    clear()

    print(BANNER)

    warning("""
Requirements:
- Pterodactyl Panel must already be installed
- NGINX must already be installed
- Script must be run as root

DANGER:
This installer may:
- Delete existing nginx configurations
- Delete existing firewall rules
- Replace existing cloudflared services
- Overwrite Cloudflare firewall rules
- Restrict server ports using UFW
""")

    print(f"{CYAN}Tutorial:{RESET} {TUTORIAL_URL}\n")

    api_key = input(f"{CYAN}Cloudflare API Token:{RESET} ").strip()

    panel_url = input(f"{CYAN}Panel URL:{RESET} ").strip()

    domain = input(f"{CYAN}Cloudflare Domain:{RESET} ").strip()

    zone_id = input(f"{CYAN}Cloudflare Zone ID:{RESET} ").strip()

    print()

    warning("Existing custom rules will be deleted.")
    warning("Existing rate limit rules will be deleted.\n")

    print("1) Continue")
    print("2) Cancel\n")

    confirm = input(f"{CYAN}Select an option:{RESET} ").strip()

    if confirm != "1":
        return

    validate_api_key(api_key)

    server_ip = get_server_ip()

    install_dependencies()

    install_tunnel()

    published_route_confirmation(panel_url, domain)

    custom_ruleset_id = get_ruleset_id(
        api_key,
        zone_id,
        "http_request_firewall_custom"
    )

    ratelimit_ruleset_id = get_ruleset_id(
        api_key,
        zone_id,
        "http_ratelimit"
    )

    wipe_rules(
        api_key,
        zone_id,
        custom_ruleset_id
    )

    wipe_rules(
        api_key,
        zone_id,
        ratelimit_ruleset_id
    )

    check_existing_nginx(panel_url)

    deploy_nginx_config(panel_url)

    deploy_custom_rules(
        api_key,
        zone_id,
        custom_ruleset_id,
        server_ip
    )

    deploy_rate_limit(
        api_key,
        zone_id,
        ratelimit_ruleset_id
    )

    configure_ufw()

    success("FlyingAura Protection Installed Successfully.")

    pause()

# =========================================================
# HELP MENU
# =========================================================
def help_menu():

    clear()

    print(BANNER)

    print("FlyingAura Cloudflare Protection Installer\n")

    print("- Installs cloudflared")
    print("- Deploys firewall protection")
    print("- Deploys nginx protection")
    print("- Deploys rate limiting")
    print("- Protects Pterodactyl panels\n")

    print(f"Tutorial: {TUTORIAL_URL}\n")
    print(f"Discord: https://discord.gg/hexiumnodes\n")

    pause()

# =========================================================
# MAIN MENU
# =========================================================
def main_menu():

    while True:

        clear()

        print(BANNER)

        print("1) Install Protection")
        print("2) Help")
        print("3) Exit\n")

        choice = input(f"{CYAN}Select an option:{RESET} ").strip()

        if choice == "1":
            install_protection()

        elif choice == "2":
            help_menu()

        elif choice == "3":
            sys.exit(0)

        else:
            error("Invalid option.")
            pause()

# =========================================================
# START PROGRAM
# =========================================================
if __name__ == "__main__":
    main_menu()
