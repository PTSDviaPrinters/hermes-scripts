#!/usr/bin/env python3
"""Context status helper — matches Hermes CLI runtime_footer format exactly.

Usage: python context-status.py [--chars N] [--no-update]
  --chars N    Use character count instead of session tokens (for testing)
  --no-update  Don't update state file (read-only mode)

Output: same format as Hermes CLI footer
  qwen3.6-35b-a3b · 25% · ~/.hermes/hermes-agent
"""

import json
import os
import sys
import yaml

HERMES_HOME = os.environ.get('HERMES_HOME', os.path.expanduser('~/.hermes'))
STATE_FILE = os.path.join(HERMES_HOME, 'context-status.json')
SESSIONS_FILE = os.path.join(HERMES_HOME, 'sessions/sessions.json')

# Qwen default context length (vLLM doesn't report it for GGUF models)
CONTEXT_LENGTH = 131072  # 128K
SEP = " · "

def get_last_prompt_tokens():
    """Get last_prompt_tokens from the current session metadata."""
    try:
        with open(SESSIONS_FILE) as f:
            data = json.load(f)
        if isinstance(data, dict):
            key = list(data.keys())[-1]
            session = data[key]
            return session.get('last_prompt_tokens', 0) or 0
    except Exception:
        pass
    return 0

def get_model_name():
    """Get the current model name from config, matching Hermes format."""
    try:
        config_path = os.path.join(HERMES_HOME, 'config.yaml')
        with open(config_path) as f:
            c = yaml.safe_load(f)
        model_cfg = c.get('model')
        if isinstance(model_cfg, dict):
            model = model_cfg.get('default', '')
        elif isinstance(model_cfg, str):
            model = model_cfg
        else:
            model = ''
        if model:
            return model.rsplit('/', 1)[-1]
    except Exception:
        pass
    return "qwen3.6-35b-a3b"

def get_cwd_short():
    """Get current working directory, relative to HOME, with forward slashes."""
    cwd = os.getcwd()
    try:
        home = os.path.expanduser('~')
        if cwd.startswith(home):
            rel = '~' + cwd[len(home):]
            return rel.replace('\\', '/')
    except Exception:
        pass
    return cwd.replace('\\', '/')

def calculate_pct(tokens, context_length=CONTEXT_LENGTH):
    """Calculate context percentage — same formula as Hermes CLI."""
    if context_length <= 0:
        return 0
    return max(0, min(100, round((tokens / context_length) * 100)))

# Context warning thresholds (percentage)
WARNING_THRESHOLD = 50  # Show warning at 50%+
CRITICAL_THRESHOLD = 80  # Show critical at 80%+

def main():
    args = sys.argv[1:]
    use_chars = False
    char_count = 0
    no_update = False

    i = 0
    while i < len(args):
        if args[i] == '--chars' and i + 1 < len(args):
            use_chars = True
            char_count = int(args[i + 1])
            i += 2
        elif args[i] == '--no-update':
            no_update = True
            i += 1
        else:
            i += 1

    # Get token count
    if use_chars:
        tokens = max(0, char_count // 4)  # rough chars-to-tokens
    else:
        tokens = get_last_prompt_tokens()

    # Calculate
    pct = calculate_pct(tokens)

    # Add warning indicator
    indicator = ""
    if pct >= CRITICAL_THRESHOLD:
        indicator = " 🔴"  # red circle
    elif pct >= WARNING_THRESHOLD:
        indicator = " 🟠"  # orange circle

    # Build footer — same format as Hermes CLI
    model = get_model_name()
    cwd = get_cwd_short()

    parts = [model, f"{pct}%{indicator}"]
    if cwd:
        parts.append(cwd)

    print(SEP.join(parts))

if __name__ == '__main__':
    main()
