# Contributing to NovaApp

Thank you for your interest in contributing to NovaApp! This guide will help you get started.

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help create a welcoming environment for all contributors

## Getting Started

### Prerequisites

- Flutter SDK ^3.10.8
- Dart SDK ^3.10.8
- Git
- A Supabase account (for testing)

### Setup

```bash
# Fork and clone the repository
git clone https://github.com/your-username/NovaApp.git
cd NovaApp

# Install dependencies
flutter pub get

# Create a branch for your changes
git checkout -b feature/your-feature-name

# Run the app
flutter run
```

## Development Guidelines

### Code Style

- Follow the Dart style guide
- Use `dart format` before committing
- Run `dart analyze` and fix all warnings
- Use meaningful variable and function names
- Add comments only when necessary (avoid obvious comments)

### Architecture

- Follow the existing feature-based structure
- Keep services focused on a single responsibility
- Use Riverpod for state management and dependency injection
- Never put business logic in widgets

### Security

- **Never** commit secrets, API keys, or credentials
- **Never** log sensitive data (PINs, keys, tokens)
- **Always** sanitize user inputs
- **Always** use parameterized queries
- **Always** follow the principle of least privilege

### Commit Messages

Use clear, descriptive commit messages:

```
feat: add message reactions
fix: resolve typing indicator leak
refactor: extract media compression logic
docs: update security policy
test: add X3DH unit tests
```

### Pull Request Process

1. **Create a feature branch** from `main`
2. **Make your changes** following the guidelines above
3. **Write tests** for new functionality
4. **Update documentation** if needed
5. **Run tests and linter:**
   ```bash
   flutter test
   dart analyze
   dart format --set-exit-if-changed .
   ```
6. **Submit a pull request** with a clear description

### What We're Looking For

- Bug fixes
- Performance improvements
- Security enhancements
- Documentation improvements
- Test coverage increases
- New features (discuss in an issue first)

### What We're NOT Looking For

- Changes that break the security model
- Dependencies that add significant bundle size
- Features that compromise user privacy
- Code that doesn't follow existing patterns

## Reporting Issues

### Bug Reports

Include:
- Steps to reproduce
- Expected behavior
- Actual behavior
- Device/OS information
- Flutter version

### Security Vulnerabilities

**Do NOT open public issues for security vulnerabilities.**

Instead, please see [SECURITY.md](SECURITY.md) for responsible disclosure instructions.

## License

By contributing, you agree that your contributions will be licensed under the GNU General Public License v3.0.
