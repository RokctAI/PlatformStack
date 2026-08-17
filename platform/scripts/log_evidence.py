#!/usr/bin/env python3
# Copyright (c) 2026 RokctAI
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import os
import re
import sys
import json
import argparse
import subprocess
from datetime import datetime

def parse_args():
    parser = argparse.ArgumentParser(description="Log continuous compliance evidence to PlatformStack (Public Repo)")
    parser.add_argument("--control-id", required=True, help="SOC 2 Control ID (e.g. SOC2-CC6.1)")
    parser.add_argument("--status", choices=["PASS", "FAIL"], required=True, help="Status of the check (PASS/FAIL)")
    parser.add_argument("--system", required=True, help="Name of system or test suite running the check")
    parser.add_argument("--detail", required=True, help="Detailed explanation of the check result or verification proof")
    args = parser.parse_args()
    # Guard against path traversal: control_id is used to build a filesystem path.
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.control_id) or ".." in args.control_id or os.sep in args.control_id:
        parser.error("--control-id must match [A-Za-z0-9._-]+ and contain no '..' or path separators")
    return args

def sanitize_text(text):
    """
    Sanitize text to remove sensitive information before committing to a public repository.
    Includes removing IPs, credentials/passwords, absolute paths, and token patterns.
    """
    if not isinstance(text, str):
        return text

    # 1. Sanitize IPv4 addresses
    text = re.sub(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '[REDACTED_IP]', text)

    # 2. Sanitize user home directories and Windows/UNIX absolute system paths
    # Replace C:\Users\username or /home/username paths with general placeholder
    text = re.sub(r'[A-Za-z]:\\[Uu]sers\\[^\\]+', r'[WORKSPACE_ROOT]', text)
    text = re.sub(r'/home/[^/]+', r'[WORKSPACE_ROOT]', text)

    # 3. Sanitize potential credentials/secrets/tokens in key-value format (e.g. pass=xyz, token=abc)
    text = re.sub(r'(?i)(password|passwd|secret|token|key|auth|credential|api_key|pkey)\s*[:=]\s*[^\s,;]+', r'\1=[REDACTED]', text)

    # 4. Redact bare token literals (GitHub PATs and similar prefixed tokens)
    text = re.sub(r'\b(?:gh[posru]|github_pat)_[A-Za-z0-9_]+', '[REDACTED_TOKEN]', text)

    # 5. Redact PEM private-key blocks
    text = re.sub(r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----',
                  '[REDACTED_PRIVATE_KEY]', text, flags=re.DOTALL)

    # 6. Redact Bearer authorization tokens
    text = re.sub(r'(?i)\bBearer\s+[A-Za-z0-9._\-]+', 'Bearer [REDACTED]', text)

    # 7. Redact credentials embedded in connection-string userinfo (scheme://user:pass@host)
    text = re.sub(r'://([^:@/\s]+):([^@/\s]+)@', r'://\1:[REDACTED]@', text)

    return text

def main():
    args = parse_args()
    
    # Calculate directories relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    platform_stack_dir = os.path.abspath(os.path.join(script_dir, "..", ".."))
    
    evidence_dir = os.path.join(platform_stack_dir, ".rokct", "evidence", args.control_id)
    os.makedirs(evidence_dir, exist_ok=True)
    
    timestamp = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    filename = f"{timestamp}_{args.status}.json"
    filepath = os.path.join(evidence_dir, filename)
    
    # Sanitize inputs to prevent accidental leaks in public repository history
    clean_system = sanitize_text(args.system)
    clean_detail = sanitize_text(args.detail)
    
    payload = {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "control_id": args.control_id,
        "status": args.status,
        "system": clean_system,
        "detail": clean_detail
    }
    
    # Write evidence file
    try:
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, ensure_ascii=False)
        print(f"Evidence logged to: {filepath}")
    except Exception as e:
        print(f"Error writing evidence file: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
