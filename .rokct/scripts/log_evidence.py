#!/usr/bin/env python3
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
    return parser.parse_args()

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
