# Ansible Validation Workflow

## Overview

This project uses a **fail-fast validation strategy** to catch Ansible syntax errors in development before they waste infrastructure resources on builds and machine provisioning.

**Problem Solved:** Build #79-80 failures revealed that syntax errors were reaching Jenkins after 15+ minutes of provisioning VMs, installing Docker, pulling images, etc. This is inefficient and violates the principle of "detect errors as early as possible."

**Solution:** Multi-layer validation:
1. **Local validation script** - Developers run manually during development
2. **Pre-commit hook** - Automatically validates before commits
3. **CI/CD integration** - (Future) Jenkins pipeline will run validation first

---

## Quick Start

### Validate All Playbooks and Roles

```bash
./scripts/validate-ansible.sh
```

Output:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Ansible Validation Suite
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▶ YAML Lint (roles & playbooks)
⊘ YAML Lint (roles & playbooks) skipped (yamllint not available)
  Install with: sudo apt install yamllint

▶ Ansible Lint (local roles)
⊘ Ansible Lint (local roles) skipped (ansible-lint not available)
  Install with: sudo apt install ansible-lint

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Validation Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Passed:  0
Failed:  0
Skipped: 2

⊘ No validation tools available
Install tools to enable validation:
  sudo apt install yamllint ansible-lint
```

### Install Validation Tools

**Option 1: System packages (recommended)**
```bash
sudo apt install yamllint ansible-lint
```

**Option 2: Python venv (if system packages not available)**
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install yamllint ansible-lint
```

---

## Validation Layers

### 1. Pre-commit Hook (Automatic)

The `.git/hooks/pre-commit` hook runs automatically when you commit files.

**How it works:**
- Checks if any `.yml` or `.yaml` files are in the staged changes
- If yes, runs `./scripts/validate-ansible.sh`
- If validation fails, the commit is **blocked**
- If validation passes, the commit proceeds

**Example:**
```bash
$ git add roles/la-compose/tasks/main.yml
$ git commit -m "Fix task ordering"

# Pre-commit hook runs automatically...
[main c0567e1] fix: ensure docker_compose_data_dir exists
```

**Force commit without validation** (not recommended):
```bash
git commit --no-verify -m "Skip validation"
```

### 2. Local Validation (Manual)

Run validation anytime before pushing:
```bash
./scripts/validate-ansible.sh
```

### 3. CI/CD Integration (Future)

The validation script is designed to be integrated into Jenkins:
```groovy
stage('Validate Ansible') {
    steps {
        sh './scripts/validate-ansible.sh'
    }
}
```

This will run **first** in the pipeline, before any provisioning, and fail fast with clear errors.

---

## What Gets Validated

### ✓ YAML Lint
- **What:** YAML syntax and structure validation
- **Tool:** `yamllint`
- **Scope:** `roles/` and `playbooks/` directories
- **Catches:**
  - Indentation errors
  - Invalid YAML syntax
  - Missing quotes
  - Duplicate keys
  - Line too long warnings

### ✓ Ansible Lint
- **What:** Ansible best practices and rules
- **Tool:** `ansible-lint`
- **Scope:** Local `roles/` directory (excludes external ala-install roles)
- **Catches:**
  - Task naming issues
  - Deprecated modules
  - Security warnings
  - Performance issues
  - Best practice violations

### ⊘ Ansible Playbook Syntax Check
- **Why skipped:** Full playbook syntax check requires all external roles to be available (ala-install, etc.)
- **When it will work:** Jenkins CI/CD stage has all dependencies
- **Local workaround:** Test specific playbooks individually

---

## Understanding Validation Output

### ✓ Passed
```
▶ YAML Lint (roles & playbooks)
✓ YAML Lint (roles & playbooks) passed
```
No errors found. Safe to commit and push.

### ✗ Failed
```
▶ YAML Lint (roles & playbooks)
✗ YAML Lint (roles & playbooks) failed
roles/la-compose/tasks/validate-pre-deploy.yml:50:81: line too long (85 > 80 characters)
```
Validation found errors. Fix them before committing.

### ⊘ Skipped
```
▶ YAML Lint (roles & playbooks)
⊘ YAML Lint (roles & playbooks) skipped (yamllint not available)
  Install with: sudo apt install yamllint
```
Tool not installed. Install if you want this validation layer.

---

## Exit Codes

- **Exit 0:** All validations passed OR only skipped (tools not available)
- **Exit 1:** At least one validation failed

Used by CI/CD and hooks to determine if commit/build should proceed.

---

## Troubleshooting

### Pre-commit hook not running

**Check if hook is executable:**
```bash
ls -la .git/hooks/pre-commit
# Should show: -rwxr-xr-x (executable)
```

**Re-enable if disabled:**
```bash
chmod +x .git/hooks/pre-commit
```

### Validation tools not found

**Install:**
```bash
sudo apt install yamllint ansible-lint
```

**Or use venv:**
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install yamllint ansible-lint
```

### Tool installed but still not found

**Check PATH:**
```bash
which yamllint
# Should return: /usr/bin/yamllint (or similar)

# If using venv, activate first:
source .venv/bin/activate
which yamllint
```

### "set -o pipefail" errors in validation

**This has been fixed** in commit `f1f42aa`. The validation script no longer uses pipefail for compatibility with /bin/sh (dash).

---

## Best Practices

### ✓ Do

1. **Run validation before pushing:**
   ```bash
   ./scripts/validate-ansible.sh
   git push
   ```

2. **Install validation tools early:**
   ```bash
   sudo apt install yamllint ansible-lint
   ```

3. **Read error messages carefully** - they're detailed and actionable

4. **Check pre-commit hook is executable:**
   ```bash
   ls -la .git/hooks/pre-commit
   ```

### ✗ Don't

1. **Don't ignore validation failures** - they indicate real issues

2. **Don't use `--no-verify` to skip validation** - defeats the purpose

3. **Don't rely only on CI/CD validation** - catch errors locally first

4. **Don't commit without running validation** - wastes infrastructure

---

## Related Issues

- **Build #79:** Pre-deployment validation failed due to shell incompatibility (`set -o pipefail`)
  - Fixed in commit `f1f42aa`

- **Build #80:** Directory not found error when building images
  - Root cause: `docker_compose_data_dir` not created before build tasks
  - Fixed in commit `c0567e1` by ensuring directory exists early

- **General:** Syntax errors reaching Jenkins after long provisioning
  - Solution: This validation workflow (commit `9c73d94`)

---

## See Also

- `AGENTS.md` - Build agent guidelines for this project
- `Jenkinsfile` - CI/CD pipeline that will integrate validation
- `.yamllint` - YAML lint configuration
- `ansible.cfg` - Ansible configuration
