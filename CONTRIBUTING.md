# Contributing to WhisperType

Thank you for your interest in contributing to WhisperType! This document provides guidelines and instructions for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a feature branch (`git checkout -b feature/amazing-feature`)
4. Make your changes
5. Run tests to ensure everything works (`./scripts/test.sh`)
6. Commit your changes
7. Push to your fork
8. Open a Pull Request

## Development Setup

### Requirements
- macOS 14 or newer
- Swift 6.3 (or compatible version with Swift tools 5.9)
- Apple Command Line Tools
- No third-party dependencies required

### Building and Testing

```bash
# Run tests
./scripts/test.sh

# Run specific tests
./scripts/test.sh --filter TestName

# Build the application
./scripts/build-app.sh

# The built app will be at dist/WhisperType.app
```

## Code Guidelines

- Follow Swift style conventions
- Use meaningful variable and function names
- Keep functions focused and readable
- Add comments for non-obvious logic
- Test your changes locally before submitting

## Reporting Issues

Please use GitHub Issues to report bugs or suggest features. When reporting a bug, include:
- macOS version
- Swift version (if relevant)
- Steps to reproduce
- Expected vs actual behavior
- Any error messages

## Pull Request Process

1. Update the README.md or documentation if needed
2. Ensure all tests pass locally
3. Provide a clear description of your changes
4. Link any related issues
5. Be open to feedback and discussion

## Code of Conduct

This project adheres to the Contributor Covenant Code of Conduct. By participating, you are expected to uphold this code. Please report unacceptable behavior to the project maintainers.

## Questions?

Feel free to open an issue to ask questions or discuss ideas for improvements.
