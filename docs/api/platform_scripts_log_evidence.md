# API Reference: log_evidence

Source file: `platform/scripts/log_evidence.py`

## Documented Module Functions

### `def sanitize_text(text)`
Sanitize text to remove sensitive information before committing to a public repository.
Includes removing IPs, credentials/passwords, absolute paths, and token patterns.
