# gh-secure

A [GitHub CLI](https://cli.github.com) extension to enable security features on repositories, following best practices from [GitHub Security Lab](https://securitylab.github.com/protect-your-project.html).

## Installation

```bash
gh extension install <owner>/gh-secure
```

### Prerequisites

- [GitHub CLI](https://cli.github.com) (`gh`) installed and authenticated
- Admin or maintainer permissions on the target repository

## Usage

```bash
gh secure                                  # Interactive mode, all features
gh secure --all                            # Enable all features, no prompts
gh secure branch-protection dependabot     # Enable only these two features
gh secure bp ss cs --all                   # Enable 3 features, no prompts
gh secure --repo owner/repo code-scanning  # Enable CodeQL on specific repo
gh secure --all --dry-run                  # Preview what would be enabled
gh secure status                           # Check current feature status
gh secure status --repo owner/repo         # Check status of specific repo
```

### Flags

| Flag | Description |
|------|-------------|
| `-r`, `--repo <owner/repo>` | Target repository (default: current repo) |
| `-a`, `--all` | Enable all features without prompting |
| `-n`, `--dry-run` | Simulate changes without applying them |
| `-v`, `--version` | Print version |
| `-h`, `--help` | Show help message |

### Feature Names

Pass one or more feature names to enable only specific features. If none are specified, all features are included.

| Feature | Shorthand |
|---------|-----------|
| `branch-protection` | `bp` |
| `vulnerability-reporting` | `vr` |
| `secret-scanning` | `ss` |
| `dependabot` | `dep` |
| `code-scanning` | `cs` |

## Security Features

This tool enables five security features based on [GitHub Security Lab recommendations](https://securitylab.github.com/protect-your-project.html):

### 1. Branch Protection
Branch protection blocks unwanted changes to your project. Prevent accidental or malicious commits that may introduce vulnerabilities or disrupt the stability of your project. Branch rules give you flexible control over who can force push, delete, etc. [Documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches)

### 2. Private Vulnerability Reporting
Security Policy and Private Vulnerability Reporting (PVR) create a safe path for reporting vulnerabilities before they go public. Make it easy for people external to the project, such as users and security researchers, to report security bugs privately. [Documentation](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)

### 3. Secret Scanning
Sensitive data like API keys, tokens, and passwords can accidentally be committed to your repository. Secret scanning with push protection guards over 300 token types and patterns from more than 180 service providers. [Documentation](https://docs.github.com/code-security/secret-scanning/about-secret-scanning)

### 4. Dependabot
Dependabot keeps your dependencies safe effortlessly. Automatically checks your dependencies for known vulnerabilities and create pull requests to update them to safe versions. This saves you the hassle of manual checks and blocks threats. [Documentation](https://docs.github.com/en/code-security/getting-started/dependabot-quickstart-guide)

### 5. Code Scanning (CodeQL)
GitHub code scanning automatically detects common security vulnerabilities in your project and in your pull requests. Resolve them manually or with the help of Copilot Autofix AI-powered suggestions, before they are exploited against you and your users. [Documentation](https://docs.github.com/en/code-security/code-scanning/introduction-to-code-scanning/about-code-scanning)

## Troubleshooting

### "403 Forbidden" Errors
Ensure you have admin or maintain permissions on the repository. For org repos, you may need `admin:org` scope — run `gh auth refresh -s admin:org`.

### Code Scanning Fails
Ensure the repository contains [supported languages](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/) and that code scanning is available for your plan.

### Branch Protection Fails
Some organizations have policies that restrict branch protection. Contact your org admin.

## Resources

- [GitHub Security Lab: Protect Your Project](https://securitylab.github.com/protect-your-project.html)
- [GitHub Security Documentation](https://docs.github.com/en/code-security)
- [CodeQL Documentation](https://codeql.github.com/docs/)

## License

MIT License
