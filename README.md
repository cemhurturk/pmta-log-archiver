# PowerMTA Log Archiver

A self-contained Bash script that automatically archives PowerMTA accounting logs to Cloudflare R2 storage. It keeps the last N days of logs locally and moves older files to cloud storage for long-term retention.

## Features

- **Self-configuring**: Interactive setup wizard guides you through configuration
- **Auto-installs dependencies**: Automatically installs `rclone` and `jq` if not present
- **Safe archival**: Only deletes local files after verifying successful upload (size verification)
- **Organized storage**: Archives files in year-month folders (e.g., `pmta-logs/2024-01/`)
- **Secure**: Configuration file stored with 600 permissions, credentials never logged
- **Idempotent**: Safe to run multiple times; already-archived files are skipped
- **Cross-distro support**: Works on Debian, Ubuntu, CentOS, RHEL, Fedora, openSUSE, and Arch Linux

## Requirements

- Linux server running PowerMTA
- Cloudflare R2 bucket and API credentials
- Root/sudo access (for dependency installation and cron setup)

The script will automatically install these dependencies if missing:
- `rclone` - Cloud storage sync tool
- `jq` - JSON parsing utility
- `curl` or `wget` - For downloads (usually pre-installed)

## Quick Start

### 1. Download the Script

```bash
sudo curl -o /usr/local/bin/pmta-log-archiver \
  https://raw.githubusercontent.com/cemhurturk/pmta-log-archiver/main/pmta-log-archiver.sh
sudo chmod +x /usr/local/bin/pmta-log-archiver
```

### 2. Run Setup

```bash
sudo pmta-log-archiver --setup
```

The setup wizard will prompt you for:
- PowerMTA log directory (default: `/var/log/pmta-accounting`)
- Log file pattern (default: `oempro-*.csv`)
- Number of days to keep locally (default: 7)
- Cloudflare R2 credentials

### 3. Set Up Automatic Archival

```bash
sudo pmta-log-archiver --install-cron
```

This creates a cron job that runs daily at 2:00 AM.

## Usage

```
pmta-log-archiver [command]

Commands:
  --setup           Run interactive setup wizard
  --run             Run the archival process
  --status          Show current status
  --list-remote     List files in R2 bucket
  --test            Test R2 connection
  --install-cron    Install daily cron job
  --remove-cron     Remove cron job
  --update          Update script to latest version
  --help            Show help message
```

### Examples

```bash
# First-time setup
sudo pmta-log-archiver --setup

# Run archival manually
sudo pmta-log-archiver --run

# Check configuration and status
pmta-log-archiver --status

# List archived files in R2
pmta-log-archiver --list-remote

# Test R2 connection
pmta-log-archiver --test

# Update to latest version
sudo pmta-log-archiver --update
```

## Configuration

Configuration is stored in `/etc/pmta-log-archiver/config` with the following options:

| Variable | Description | Default |
|----------|-------------|---------|
| `LOG_DIR` | Directory containing PowerMTA logs | `/var/log/pmta-accounting` |
| `LOG_PATTERN` | Glob pattern for log files | `oempro-*.csv` |
| `RETENTION_DAYS` | Days to keep logs locally | `7` |
| `R2_ACCOUNT_ID` | Cloudflare account ID | - |
| `R2_BUCKET` | R2 bucket name | - |
| `R2_PATH` | Path prefix in bucket | `pmta-logs` |
| `R2_ACCESS_KEY_ID` | R2 API access key | - |
| `R2_SECRET_ACCESS_KEY` | R2 API secret key | - |

## Getting Cloudflare R2 Credentials

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/) > R2
2. Create a bucket if you haven't already
3. Click **Manage R2 API Tokens**
4. Create a new API token with read/write access to your bucket
5. Note down the Access Key ID and Secret Access Key

Your Account ID can be found in the R2 dashboard URL or in the bucket settings.

## R2 Storage Structure

Archived files are organized by year and month:

```
{bucket}/{R2_PATH}/{YYYY-MM}/{filename}

Example:
my-bucket/pmta-logs/2024-01/oempro-2024-01-15-0001.csv
my-bucket/pmta-logs/2024-01/oempro-2024-01-15-0002.csv
my-bucket/pmta-logs/2024-02/oempro-2024-02-01-0001.csv
```

## PowerMTA Log Format

The script expects log files named in this pattern:
```
{prefix}-YYYY-MM-DD-NNNN.csv
```

Where:
- `prefix` - Configurable via `LOG_PATTERN` (default: `oempro`)
- `YYYY-MM-DD` - Date the log was created
- `NNNN` - Sequence number (rolls over at ~250MB)

## File Locations

| Path | Purpose |
|------|---------|
| `/usr/local/bin/pmta-log-archiver` | Installed script |
| `/etc/pmta-log-archiver/config` | Configuration file |
| `/var/log/pmta-log-archiver.log` | Runtime logs |
| `/etc/cron.d/pmta-log-archiver` | Cron job |

## Troubleshooting

### Common Issues

**"Permission denied"**
Run commands with `sudo` for setup, install, and run operations.

**"R2 connection failed"**
- Verify your Account ID, Access Key ID, and Secret Access Key
- Ensure the bucket exists
- Check that your API token has read/write permissions

**"Size mismatch"**
Network issue during upload. The script will retry automatically. Re-run if needed.

**"No files found"**
Check that `LOG_DIR` and `LOG_PATTERN` in your config match your actual log files.

### Debug Mode

Run with verbose output:
```bash
bash -x /usr/local/bin/pmta-log-archiver --run
```

### Check Logs

```bash
tail -f /var/log/pmta-log-archiver.log
```

## Security Considerations

- Configuration file has 600 permissions (owner read/write only)
- Secret keys are never logged
- All user input is validated during setup
- Uploads are verified with checksum before deleting local files
- R2 credentials should have minimal required permissions

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Author

Created by [Octeth](https://octeth.com) for PowerMTA log management.
