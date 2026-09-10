# Contributing to my-package

Thank you for your interest in contributing! This document provides guidelines and instructions for contributing to this project.

## Table of Contents

- [Development Setup](#development-setup)
- [Development Workflow](#development-workflow)
- [Code Standards](#code-standards)
- [Testing Guidelines](#testing-guidelines)
- [Changesets](#changesets)
- [Pull Request Process](#pull-request-process)
- [Release Process](#release-process)

## Development Setup

### Prerequisites

- **Java 17+**: Required for building and running the project
- **Maven 3.8+**: Build tool and dependency manager
- **Node.js 20+ or Bun**: For running CI/CD scripts
- **Git**: Version control
- **pre-commit** (optional): For automated pre-commit hooks

### Initial Setup

1. **Fork and clone the repository**:

   ```bash
   git clone https://github.com/YOUR_USERNAME/java-ai-driven-development-pipeline-template.git
   cd java-ai-driven-development-pipeline-template
   ```
2. **Verify Java and Maven versions**:

   ```bash
   java --version    # Should be 17+
   mvn --version     # Should be 3.8+
   ```
3. **Install dependencies and build**:

   ```bash
   mvn clean install
   ```
4. **Install pre-commit hooks** (optional but recommended):

   ```bash
   pip install pre-commit
   pre-commit install
   ```

## Development Workflow

### Creating a Feature Branch

```bash
git checkout -b feature/your-feature-name
```

### Making Changes

1. Make your code changes
2. Write or update tests
3. Run quality checks:

   ```bash
   # Format code
   mvn spotless:apply

   # Run all checks
   mvn verify

   # Or run individual checks
   mvn spotless:check    # Format check
   mvn spotbugs:check    # Static analysis
   mvn test              # Unit tests
   ```
4. Create a changeset (see [Changesets](#changesets))
5. Commit your changes:

   ```bash
   git add .
   git commit -m "feat: add your feature description"
   ```

### Running Tests

```bash
# Run all tests
mvn test

# Run tests with coverage report
mvn test jacoco:report

# View coverage report
open target/site/jacoco/index.html
```

### Code Formatting

We use [Spotless](https://github.com/diffplug/spotless) with Google Java Format:

```bash
# Check formatting
mvn spotless:check

# Apply formatting
mvn spotless:apply
```

## Code Standards

### Style Guidelines

- **Google Java Style**: All code must conform to [Google Java Style Guide](https://google.github.io/styleguide/javaguide.html)
- **Line length**: Maximum 100 characters
- **Indentation**: 2 spaces (Google style)
- **Imports**: Organized and no wildcards

### Documentation

- All public classes and methods must have Javadoc
- Include `@param`, `@return`, and `@throws` tags as appropriate
- Write clear, concise descriptions

Example:

```java
/**
 * Adds two numbers together.
 *
 * @param a the first number
 * @param b the second number
 * @return the sum of a and b
 */
public static long add(long a, long b) {
  return a + b;
}
```

### Best Practices

- Keep methods focused and under 50 lines
- Keep classes under 500 lines
- Keep files under 1000 lines (enforced by CI)
- Use meaningful variable and method names
- Avoid nested callbacks and complex control flow
- Prefer immutability where possible
- Use `final` for class fields when appropriate

## Testing Guidelines

### Test Organization

- Place tests in `src/test/java/` mirroring the source structure
- Name test classes with `Test` suffix: `MyPackageTest.java`
- Use descriptive test method names

### Test Structure

We use JUnit 5 with nested test classes for organization:

```java
@DisplayName("MyPackage")
class MyPackageTest {

  @Nested
  @DisplayName("add()")
  class AddTests {

    @Test
    @DisplayName("adds positive numbers correctly")
    void addsPositiveNumbers() {
      assertEquals(5, MyPackage.add(2, 3));
    }
  }
}
```

### Coverage Requirements

- Aim for 80%+ code coverage
- All public methods should have tests
- Include edge cases and error conditions

## Changesets

We use a changeset-based workflow (similar to JavaScript's `@changesets/cli`) to manage version bumps and changelogs. This approach:

- **Avoids merge conflicts** when multiple PRs are open
- **Associates changes with PRs** for better traceability
- **Determines version bump automatically** from changesets

### Creating a Changeset

For every PR that changes source code, add a changeset file:

```bash
# Using the script (recommended)
bun scripts/create-manual-changeset.mjs --bump-type patch --description "Fix a bug"
bun scripts/create-manual-changeset.mjs --bump-type minor --description "Add new feature"
bun scripts/create-manual-changeset.mjs --bump-type major --description "Breaking change"
```

Or create manually in `.changeset/`:

```markdown
---
'my-package': patch
---

Description of the changes made.
```

### Changeset Format

Each changeset has two parts:

1. **Frontmatter** (between `---` markers):
   - Package name and version bump type (major, minor, or patch)
2. **Description**:
   - Clear description of what changed
   - Use present tense ("Add feature" not "Added feature")
   - Reference issue numbers when applicable: "Fix login bug (#123)"

### Version Bump Types

- **patch**: Bug fixes, documentation updates, internal changes
- **minor**: New features, non-breaking enhancements
- **major**: Breaking changes, API changes

### Example Changeset

```markdown
---
'my-package': minor
---

Add async delay function with CompletableFuture support for non-blocking operations.
```

## Pull Request Process

### Before Submitting

1. Ensure all tests pass: `mvn verify`
2. Format your code: `mvn spotless:apply`
3. Create a changeset for source changes
4. Update documentation if needed

### PR Requirements

- Clear, descriptive title
- Description of changes
- Link to related issue (if applicable)
- All CI checks must pass
- At least one approval from maintainers

### PR Title Convention

Use conventional commit format:

- `feat: add new feature`
- `fix: resolve bug in X`
- `docs: update README`
- `refactor: improve code structure`
- `test: add tests for Y`
- `chore: update dependencies`

## Release Process

Releases are automated through GitHub Actions using the changeset workflow.

### How It Works

1. **PR Development**: Each PR includes a changeset describing the change
2. **PR Merge**: When PRs are merged to `main`, changesets accumulate
3. **Auto Release**: The release job detects pending changesets and:
   - Merges multiple changesets (highest bump type wins)
   - Bumps version according to changesets
   - Updates CHANGELOG.md
   - Creates a GitHub release
   - Uploads JAR artifacts

### Release Modes (via workflow_dispatch)

|      Mode      |                  Description                  |
|----------------|-----------------------------------------------|
| `changeset`    | Release based on pending changesets (default) |
| `instant`      | Direct version bump without changesets        |
| `changeset-pr` | Create a PR with a new changeset              |

### Manual Release

Maintainers can trigger a release via GitHub Actions:

1. Go to Actions > CI/CD Pipeline
2. Click "Run workflow"
3. Select release mode and options

### Version Numbering

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

## Questions?

If you have questions, please:

1. Check existing issues
2. Open a new issue with your question
3. Tag it with the `question` label

Thank you for contributing!
