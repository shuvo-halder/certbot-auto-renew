
```markdown
# 🔐 Certbot Auto Renewal Script 

Automated SSL certificate renewal system using **Certbot**, designed for production Linux environments.

This script handles:

- OS detection (Ubuntu, Debian, CentOS, RHEL, etc.)
- Web server detection (Nginx / Apache)
- Firewall handling (UFW / firewalld / none)
- Safe SSL renewal for multiple domains
- Temporary firewall rule management
- Service reload only when needed
- Logging and error handling
- Cron-based automation

📦 GitHub Repository:  
👉 https://github.com/shuvo-halder/ssl-certbot

---

## 📦 Features

✅ Fully automated SSL renewal  
✅ Multi-domain & multi-cert support  
✅ Idempotent (safe to run multiple times)  
✅ No permanent firewall changes  
✅ Minimal downtime (no unnecessary restarts)  
✅ Production-safe logging  

---

## 📁 File Structure

```

ssl-certbot/
├── certbot-auto-renew.sh
└── README.md

````

---

## ⚙️ Requirements

- Linux server (Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux)
- Root or sudo access
- Certbot installed  
  👉 https://certbot.eff.org
- One of:
  - Nginx
  - Apache
- Optional:
  - UFW
  - firewalld

---

## 🚀 Installation

### 1. Clone Repository

```bash
git clone https://github.com/shuvo-halder/certbot-auto-renew.git
cd certbot-auto-renew
````

---

### 2. Install Script

```bash
sudo install -m 0755 certbot-auto-renew.sh /usr/local/bin/certbot-auto-renew.sh
```

---

### 3. Create Log File

```bash
sudo touch /var/log/certbot-auto-renew.log
sudo chmod 640 /var/log/certbot-auto-renew.log
```

---

## 🔍 How It Works

### Execution Flow

1. Detect OS (Ubuntu / Debian / RHEL family)
2. Detect running web server:

   * nginx
   * apache2 / httpd
3. Detect firewall:

   * UFW
   * firewalld
   * none
4. Read all certificates from:

   ```
   /etc/letsencrypt/renewal/
   ```
5. For each certificate:

   * Open required ports (80, 443) temporarily
   * Run renewal:

     ```
     certbot renew --cert-name <cert>
     ```
   * Close firewall rules safely
6. If certificate changed:

   * Reload web server
7. Write logs to:

   ```
   /var/log/certbot-auto-renew.log
   ```

---

## 🔥 Firewall Handling

### UFW

* Detects active state
* Adds rule only if missing
* Removes only rules added by script

---

### firewalld

* Detects active zones
* Adds **runtime-only rules**
* No permanent changes
* Automatically cleaned after run

---

### No Firewall

* Script skips firewall steps

---

## 🌐 Web Server Handling

| Server | Action                               |
| ------ | ------------------------------------ |
| Nginx  | `systemctl reload nginx`             |
| Apache | `systemctl reload apache2` / `httpd` |

✔ Reload only happens if certificate is updated

---

## 📜 Logging

Log file:

```
/var/log/certbot-auto-renew.log
```

Example:

```
[2026-04-16 03:00:01] Renewing certificate: example.com
[2026-04-16 03:00:05] Certificate updated; reloading nginx
[2026-04-16 03:00:06] Completed successfully.
```

---

## ⏰ Cron Setup

### Daily (Recommended)

```bash
sudo crontab -e
```

Add:

```
0 3 * * * /usr/local/bin/certbot-auto-renew.sh
```

---

### Twice Daily (High Availability)

```
0 3,15 * * * /usr/local/bin/certbot-auto-renew.sh
```

---

## 🧪 Manual Test

```bash
sudo /usr/local/bin/certbot-auto-renew.sh
```

Check logs:

```bash
tail -f /var/log/certbot-auto-renew.log
```

---

## ⚠️ Important Notes

* Renewal runs only when certificate is near expiry
* No forced renewals
* No permanent firewall changes
* Safe to run multiple times
* Lock mechanism prevents duplicate runs
* Requires root access

---

## 🛠 Troubleshooting

### Check Certificates

```bash
certbot certificates
```

---

### Dry Run

```bash
certbot renew --dry-run
```

---

### Firewall Debug

#### UFW

```bash
ufw status
```

#### firewalld

```bash
firewall-cmd --list-all
```

---

### Service Check

```bash
systemctl status nginx
systemctl status apache2
systemctl status httpd
```

---

## 🔒 Security Considerations

* Strict file permissions (`umask 027`)
* No sensitive data exposure
* Temporary firewall rules only
* No service restarts (reload only)

---

## 📌 Best Practices

* Test with `--dry-run` before production
* Monitor logs regularly
* Keep Certbot updated
* Backup `/etc/letsencrypt/`

---

## 🤝 Contributing

Feel free to fork and improve:

👉 [https://github.com/shuvo-halder/certbot-auto-renew](https://github.com/shuvo-halder/certbot-auto-renew)

---

## 📄 License

MIT License (recommended — update if different)

---

## 👨‍💻 Author

**Shuvo Halder**
System Engineer

GitHub: [https://github.com/shuvo-halder](https://github.com/shuvo-halder)

---

## ✅ Summary

This project provides:

* 🔁 Automated SSL lifecycle management
* 🔥 Smart firewall handling
* ⚙️ Multi-environment compatibility
* 🚀 Production-ready automation
