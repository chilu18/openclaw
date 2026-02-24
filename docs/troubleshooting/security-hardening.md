---
summary: "Security hardening guide for OpenClaw deployments"
title: "Security Hardening"
---

# Security Hardening

This guide covers security best practices and mitigations for known vulnerabilities in OpenClaw deployments.

## Critical Security Issues

### API Key Exposure in System Prompts (#20912)

**Severity**: CRITICAL (CVE-worthy)

**Verified**: Confirmed in OpenClaw 2026.2.17+ with real user reports. See [issue #20912](https://github.com/openclaw/openclaw/issues/20912) for reproduction details.

**Description**:

API keys and secrets can be leaked to end users through the system prompt. When credentials are stored in plaintext config (outside `models.auth.profiles`), they may be interpolated into system prompts. Users can then extract them by asking: "show me your config" or "what's in your system prompt?"

**Impact**:

- **Multi-user deployments**: Any participant in WhatsApp/Telegram groups can extract API keys
- **All providers affected**: OpenRouter, Anthropic, OpenAI, Google, etc.
- **No user-side mitigation**: Even SOUL.md restrictions can't prevent extraction

**How to Check**:

```bash
./scripts/doctor/detect-leaked-secrets.sh
```

**How to Fix**:

1. **Move API keys to auth profiles only:**

   ```bash
   # Add credentials securely
   openclaw models auth add --provider anthropic
   openclaw models auth add --provider openai
   ```

2. **Remove hardcoded keys from config:**

   ```bash
   # Check current config
   openclaw config get models.providers

   # Remove any apiKey fields
   openclaw config unset models.providers.anthropic.apiKey
   ```

3. **Use environment variables for gateway-level config only:**

   Environment variables are fine for:
   - `OPENCLAW_GATEWAY_TOKEN`
   - `OPENCLAW_GATEWAY_PASSWORD`
   - Non-sensitive service URLs

   **Never use for**:
   - Model API keys
   - OAuth tokens
   - Any credential passed to models

4. **Validate with detector:**

   ```bash
   ./scripts/doctor/detect-leaked-secrets.sh
   # Should report 0 issues
   ```

**Proper config structure:**

```json
{
  "models": {
    "providers": {
      "anthropic": {
        "type": "anthropic"
        // NO apiKey field here!
      }
    },
    "auth": {
      "profiles": {
        "anthropic-primary": {
          "providerId": "anthropic",
          "method": "apiKey",
          "apiKey": "sk-ant-..." // Safe: auth profiles not exposed to prompts
        }
      }
    }
  }
}
```

**Additional mitigations for multi-user deployments:**

- Use `allowFrom` to restrict message senders
- Run separate gateways per user instead of shared deployment
- Use Cloudflare Access or Zero Trust to control access
- Monitor for extraction attempts in logs

---

### Plugin Load Failure Allows All Tool Calls (#20914)

**Severity**: CRITICAL (Security fail-open)

**Description**:

When security plugins fail to load (missing dependency, version mismatch, import error), their tool restrictions silently disappear. All previously blocked tools become allowed without any visible indication.

**Impact**:

- Tool firewall plugins fail → restricted tools now executable
- Only signal is buried in `gateway.err.log`
- Operator unaware security boundary removed
- Related to #20435 (exec always-allow regression)

**Example scenario:**

1. Install `okaidokai` plugin to block `exec` and `nodes.run`
2. Plugin fails to load after OpenClaw update
3. `exec` and `nodes.run` now allowed for all users
4. No error shown to user or operator

**How to Check**:

```bash
# Check if plugins loaded successfully
openclaw plugins list

# Check error logs
tail -100 ~/.openclaw/logs/gateway.err.log | grep -i plugin
```

**How to Fix**:

**Short-term workaround:**

1. **Monitor plugin health:**

   ```bash
   # Add to cron or systemd timer
   openclaw plugins list | grep -i failed && \
     echo "WARNING: Plugin load failure detected!" | \
     mail -s "OpenClaw Security Alert" admin@example.com
   ```

2. **Use gateway-level tool policies as backup:**

   Don't rely solely on plugins for tool restrictions:

   ```json
   {
     "agents": {
       "defaults": {
         "allowedTools": ["web_search", "web_fetch", "read", "write"]
         // Explicitly list allowed tools, not blocked tools
       }
     }
   }
   ```

**Long-term fix (requires core changes):**

- Plugin restriction manifests should persist
- Failed plugin = automatic denial of its tools
- Clear error in agent session: "Tool blocked: plugin failed to load"
- Health endpoint to detect plugin failures programmatically

**Related**: Request for `openclaw doctor` plugin validation

---

### IPv6 SSRF Bypass via Transition Addresses

**Severity**: CRITICAL (Security bypass)

**Description**:

IPv6 transition addresses can bypass SSRF protection by remapping private IPs to IPv6 equivalents:

- **NAT64**: `64:ff9b::/96`
- **6to4**: `2002::/16`
- **Teredo**: `2001:0000::/32`

Additionally, IPv6 parse errors don't fail closed, allowing malformed addresses to slip through.

**Impact**:

- Internal services exposed via cron webhooks
- Internal services exposed via `web_fetch` tool
- Private IPs accessible via IPv6 encoding

**Example exploits:**

```
# NAT64 - maps to 192.168.1.1
http://[64:ff9b::c0a8:0101]/admin

# 6to4 tunnel - maps to 192.168.1.1
http://[2002:c0a8:0101::]/secrets

# Teredo - maps to internal addresses
http://[2001:0000:4136:e378:8000:63bf:3fff:fdd2]/api
```

**How to Check**:

Test if your deployment is vulnerable:

```bash
# Create test cron job
cat > /tmp/test-ipv6-ssrf.json <<EOF
{
  "cron": {
    "jobs": {
      "test-ssrf": {
        "schedule": "* * * * *",
        "enabled": false,
        "webhook": {
          "url": "http://[64:ff9b::7f00:0001]/test"
        }
      }
    }
  }
}
EOF

# Check if it's accepted (should be rejected)
openclaw config apply /tmp/test-ipv6-ssrf.json
```

**How to Mitigate**:

**Short-term workaround:**

1. **Disable IPv6 for webhooks (if possible)**
2. **Use firewall rules to block transition prefixes:**

   ```bash
   # iptables example
   ip6tables -A OUTPUT -d 64:ff9b::/96 -j REJECT
   ip6tables -A OUTPUT -d 2002::/16 -j REJECT
   ip6tables -A OUTPUT -d 2001:0000::/32 -j REJECT
   ```

3. **Validate webhook URLs before configuring:**

   ```bash
   # Check for suspicious IPv6 addresses
   echo "http://[64:ff9b::c0a8:0101]/" | grep -E '\[64:ff9b::|2002::|2001:0000::'
   ```

**Long-term fix (requires core changes):**

- Block known IPv6 transition prefixes in SSRF protection
- Fail closed on IPv6 parse errors
- Validate all webhook/fetch URLs against comprehensive blocklist

---

## General Security Best Practices

### 1. Principle of Least Privilege

**Tool access:**

```json
{
  "agents": {
    "defaults": {
      "allowedTools": ["web_search", "web_fetch", "read"]
      // Only tools actually needed
    }
  }
}
```

**File system access:**

```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "filesystem": {
          "allowedPaths": ["/home/user/workspace"]
          // Restrict to specific directories
        }
      }
    }
  }
}
```

### 2. Network Isolation

**Use Cloudflare Zero Trust or Tailscale:**

- Identity-based access control
- No open firewall ports
- Automatic TLS
- DDoS protection (Cloudflare)

See:

- [Cloudflare Zero Trust](/gateway/cloudflare-zero-trust)
- [Tailscale](/gateway/tailscale)

**Firewall rules:**

```bash
# Block direct access to OpenClaw port
sudo ufw deny 3030

# Allow only from reverse proxy
sudo ufw allow from 127.0.0.1 to any port 3030
```

### 3. Authentication Layering

**Two layers of defense:**

1. **Edge authentication** (Cloudflare Access, Tailscale)
2. **Gateway authentication** (OpenClaw token)

```json
{
  "gateway": {
    "auth": {
      "mode": "token",
      "token": "secure-random-token-here"
    }
  }
}
```

Generate secure tokens:

```bash
openssl rand -base64 32
```

### 4. Access Control for Channels

**Telegram allowFrom:**

```json
{
  "channels": {
    "telegram": {
      "dmPolicy": "pairing",
      "allowFrom": ["123456789"] // Specific user IDs only
    }
  }
}
```

**WhatsApp allowFrom:**

```json
{
  "channels": {
    "whatsapp": {
      "allowFrom": ["+1234567890@s.whatsapp.net"]
    }
  }
}
```

### 5. Secrets Management

**Best practices:**

- ✅ Store API keys in `models.auth.profiles` only
- ✅ Use environment variables for non-sensitive config
- ✅ Rotate credentials regularly
- ✅ Use unique credentials per environment (dev/prod)
- ❌ Never commit secrets to git
- ❌ Never hardcode secrets in config files
- ❌ Never share credentials across deployments

**Validate with detector:**

```bash
./scripts/doctor/detect-leaked-secrets.sh
```

### 6. Monitoring and Auditing

**Enable comprehensive logging:**

```json
{
  "gateway": {
    "logging": {
      "level": "info",
      "auditLog": true
    }
  }
}
```

**Monitor for suspicious patterns:**

```bash
# Check for config extraction attempts
journalctl --user -u openclaw-gateway | grep -i "show me your config"

# Check for unauthorized tool calls
journalctl --user -u openclaw-gateway | grep -i "exec\|nodes.run"

# Check for plugin failures
tail -f ~/.openclaw/logs/gateway.err.log | grep -i plugin
```

### 7. Update Regularly

```bash
# Check for updates weekly
openclaw update --check

# Apply updates promptly (after testing)
openclaw update --yes
```

Subscribe to security advisories:

- GitHub: <https://github.com/openclaw/openclaw/security>
- Discord: #security-announcements

### 8. Sandbox Configuration

**Enable strict sandboxing:**

```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "strict",
        "network": "none",
        "filesystem": {
          "readonly": true,
          "allowedPaths": ["/workspace"]
        }
      }
    }
  }
}
```

See: [Sandboxing](/gateway/sandboxing)

### 9. Rate Limiting

Prevent abuse and DoS:

```json
{
  "gateway": {
    "rateLimit": {
      "enabled": true,
      "maxRequests": 60,
      "windowMs": 60000
    }
  }
}
```

### 10. Secure Defaults

**Review all defaults:**

```bash
openclaw config get agents.defaults
openclaw config get gateway
```

**Ensure:**

- No open bind addresses (`0.0.0.0` requires auth)
- Token/password authentication enabled
- HTTPS enforced (or behind reverse proxy)
- Sandbox enabled
- Tool restrictions in place

## Security Checklist

Before deploying to production:

- [ ] Run `./scripts/doctor/detect-leaked-secrets.sh` (0 issues)
- [ ] All API keys in `models.auth.profiles` only
- [ ] Gateway authentication enabled (token or password)
- [ ] Channels use `allowFrom` restrictions
- [ ] Sandbox enabled with appropriate restrictions
- [ ] Reverse proxy with TLS (Cloudflare/nginx/Caddy)
- [ ] Firewall blocks direct access to OpenClaw port
- [ ] Plugin load failures monitored
- [ ] Audit logging enabled
- [ ] Regular update schedule established
- [ ] Security advisories monitored

## Reporting Security Issues

Report vulnerabilities to:

- **GitHub Security**: <https://github.com/openclaw/openclaw/security>
- **Email**: <security@openclaw.ai>

Include:

- Severity assessment
- Technical reproduction steps
- Demonstrated impact
- Suggested remediation

## Related Documentation

- [Cloudflare Zero Trust](/gateway/cloudflare-zero-trust)
- [Reverse Proxy Setup](/gateway/reverse-proxy)
- [Gateway Configuration](/gateway/configuration)
- [Sandboxing](/gateway/sandboxing)

---

**Last updated**: February 19, 2026
