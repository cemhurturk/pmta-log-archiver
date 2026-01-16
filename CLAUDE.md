# CLAUDE.md - PowerMTA Log Archiver

## Project Overview

This project is a self-contained Bash script that archives PowerMTA accounting logs to Cloudflare R2 storage. It keeps the last N days of logs locally and moves older files to cloud storage for long-term retention.

**Primary User:** Cem, Founder/CEO of Octeth (email marketing infrastructure)
**Environment:** Bare-metal MTA servers running PowerMTA
**Language:** Bash (POSIX-compatible where possible)

## File Structure

```
/
├── pmta-log-archiver.sh      # Main script
├── CLAUDE.md                  # This file
├── README.md                  # User documentation
└── tests/                     # Test scripts (if any)
```

## Script Locations (Production)

| Path | Purpose |
|------|---------|
| `/usr/local/bin/pmta-log-archiver` | Installed script location |
| `/etc/pmta-log-archiver/config` | Configuration file (600 permissions) |
| `/var/log/pmta-log-archiver.log` | Runtime logs |
| `/var/log/pmta-accounting/` | PowerMTA source logs |
| `/etc/cron.d/pmta-log-archiver` | Cron job file |

## Code Conventions

### Bash Style Guide

- Use `set -euo pipefail` at script start
- Quote all variables: `"$variable"` not `$variable`
- Use `[[` for conditionals, not `[`
- Use lowercase for local variables, UPPERCASE for constants/config
- Use `local` keyword for function-scoped variables
- Prefer `$(command)` over backticks
- Use `snake_case` for function names
- Add descriptive comments for complex logic

### Function Organization

```bash
# Group functions by purpose in this order:
# 1. Logging functions
# 2. Dependency management
# 3. Configuration management
# 4. Cron management
# 5. Archive functions (core logic)
# 6. Utility commands
# 7. Main entry point
```

### Error Handling

- Always check command return values for critical operations
- Use `error_exit "message"` for fatal errors
- Log errors before exiting
- Never delete local files without verifying R2 upload succeeded

## Key Design Decisions

1. **Self-contained**: Script installs its own dependencies (rclone, jq)
2. **Safe deletion**: Only removes local files after upload verification (size check)
3. **Organized storage**: Files stored in R2 by year-month folders (`pmta-logs/2026-01/`)
4. **Credentials security**: Config file has 600 permissions, secrets never logged
5. **Idempotent**: Safe to run multiple times; already-archived files are skipped

## PowerMTA Log Format

Log files follow this naming pattern:
```
oempro-YYYY-MM-DD-NNNN.csv
```

- `oempro` - Prefix (configurable via LOG_PATTERN)
- `YYYY-MM-DD` - Date the log was created
- `NNNN` - Sequence number (rolls over at ~250MB)

Files are CSV format containing email delivery/bounce/feedback data.

## Cloudflare R2 Integration

Uses `rclone` with S3-compatible API:
- Endpoint: `https://{account_id}.r2.cloudflarestorage.com`
- Provider: Cloudflare
- Authentication: Access Key ID + Secret Access Key

R2 path structure:
```
{bucket}/{R2_PATH}/{YYYY-MM}/{filename}
```

## Testing Guidelines

### Manual Testing Checklist

1. **Dependency installation**: Test on fresh system without rclone/jq
2. **Setup wizard**: Test interactive prompts and validation
3. **R2 connection**: Test with valid and invalid credentials
4. **Archive process**: Test with files older and newer than cutoff
5. **Verification**: Ensure size matching works correctly
6. **Cron installation**: Verify cron file syntax and permissions

### Test Commands

```bash
# Check syntax
bash -n pmta-log-archiver.sh

# Run with debug output
bash -x pmta-log-archiver.sh --run

# Test setup without saving
# (cancel at confirmation prompt)
./pmta-log-archiver.sh --setup
```

## Common Modifications

### Adding a New CLI Command

1. Add case in `main()` function
2. Create handler function
3. Update `show_help()` with new command
4. Document in README.md

### Changing Retention Logic

Modify `run_archive()` function, specifically:
- `get_cutoff_date()` - calculates the threshold date
- Date comparison: `if [[ "$file_date" < "$cutoff_date" ]]`

### Adding New Cloud Storage Backend

1. Add new credential variables to config
2. Create new `upload_to_*()` and `verify_*()` functions
3. Add backend selection to setup wizard
4. Update `get_*_remote()` helper function

## Security Considerations

- Config file must be mode 600 (owner read/write only)
- Never echo/log secret keys
- Validate all user input in setup wizard
- Use `--checksum` flag for rclone to verify transfers
- R2 credentials should have minimal required permissions (read/write to specific bucket)

## Dependencies

| Tool | Purpose | Installation |
|------|---------|--------------|
| `rclone` | Cloud storage sync | Auto-installed via script or package manager |
| `jq` | JSON parsing | Auto-installed via package manager |
| `bc` | Math calculations | Usually pre-installed |
| `curl` or `wget` | Downloads | Usually pre-installed |

## Supported Distributions

Tested package managers:
- `apt` (Debian/Ubuntu)
- `yum` (CentOS/RHEL 7)
- `dnf` (Fedora/RHEL 8+)
- `zypper` (openSUSE)
- `pacman` (Arch)

## Troubleshooting

### Common Issues

1. **"Permission denied"**: Run with `sudo` for setup/install operations
2. **"R2 connection failed"**: Check credentials, account ID, bucket name
3. **"Size mismatch"**: Network issue during upload; script will retry
4. **"No files found"**: Check LOG_DIR and LOG_PATTERN in config

### Debug Mode

Add `-x` flag for verbose output:
```bash
bash -x /usr/local/bin/pmta-log-archiver --run
```

## Contributing

When making changes:
1. Maintain backward compatibility with existing config files
2. Test on multiple Linux distributions if possible
3. Update help text and README for new features
4. Follow existing code style and conventions
5. Add logging for new operations

## Related Octeth Infrastructure

This script is part of Octeth's MTA infrastructure:
- PowerMTA servers generate CSV accounting logs
- Logs contain delivery, bounce, and feedback loop data
- Data is processed by Octeth's analytics pipeline
- R2 provides cost-effective long-term storage

## Contact

- **Project Owner**: Cem (Octeth)
- **Use Case**: Email marketing infrastructure log management