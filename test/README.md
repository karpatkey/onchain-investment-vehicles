# kpkShares Test Suite Organization

This directory contains the reorganized test suite for the `kpkShares` contract, structured for better maintainability, readability, and logical organization.

## 🏗️ Test Structure

### Base Infrastructure
- **`kpkShares.TestBase.sol`** - Shared test infrastructure, helper functions, and common setup
  - Contains all common setup logic, mock deployments, and helper functions
  - Provides constants and utility functions for all test domains
  - Inherits from Forge's `Test` to provide common testing utilities

### Domain-Specific Test Files
- **`kpkShares.Initialization.sol`** - Contract initialization and constructor tests
- **`kpkShares.Subscriptions.sol`** - Subscription request functionality and processing
- **`kpkShares.Redemptions.sol`** - Redemption request functionality and processing
- **`kpkShares.Fees.sol`** - Fee calculation, management, and performance fees
- **`kpkShares.Assets.sol`** - Asset approval, management, and validation
- **`kpkShares.Admin.sol`** - Administrative functions, TTL management, and roles
- **`kpkShares.Integration.sol`** - Complex workflows and cross-domain scenarios
- **`kpkShares.Upgrade.sol`** - Contract upgrade functionality and UUPS proxy

### Main Entry Point
- **`kpkShares.Main.sol`** - Main test contract that runs the core domain tests together
  - Inherits from the Initialization, Subscriptions, Redemptions, Fees, Assets, Admin, Integration, and Upgrade test contracts
  - Provides cross-domain integration tests
  - Serves as the entry point for running the core domain tests

### Additional Test Files
- **`kpkShares.ETHSubscription.sol`** - Native-ETH subscription flows (`kpkSharesETHSubscriptionTest`)
- **`kpkShares.Precision.sol`** - Rounding and precision edge cases (`kpkSharesPrecisionTest`)
- **`kpkShares.GasTest.sol`** - Gas measurement tests (`kpkSharesGasTest`)
- **`kpkShares.ParameterizedExample.sol`** - Example of parameterized/table-driven tests (`kpkSharesParameterizedExampleTest`)
- **`CcipOivDeployer.t.sol`** - Tests for the CCIP OIV deployer (`CcipOivDeployerTest`)
- **`KpkOivFactory.t.sol`** - Tests for the OIV factory (`KpkOivFactoryTest`, `KpkOivFactoryUnitTest`)

These files inherit from `kpkSharesTestBase` (the `kpkShares.*` ones) or directly from Forge's `Test`, and are run by `forge test` independently of `kpkShares.Main.sol`.

### Support Files
- **`constants.sol`** - Shared test constants
- **`errors.sol`** - Shared custom error definitions used in tests
- **`mocks/tokens.sol`** - `Mock_ERC20` token used across the suite
- **`mocks/MockCcipRouter.sol`** - Mock CCIP router used by deployer/factory tests

## 🚀 How to Use

### Running All Tests
```bash
# Run all tests in the organized structure
forge test --match-path test/kpkShares.Main.sol

# Run specific domain tests
forge test --match-path test/kpkShares.Subscriptions.sol
forge test --match-path test/kpkShares.Fees.sol
```

### Running Individual Domain Tests
```bash
# Test only initialization functionality
forge test --match-path test/kpkShares.Initialization.sol

# Test only subscription functionality
forge test --match-path test/kpkShares.Subscriptions.sol

# Test only upgrade functionality
forge test --match-path test/kpkShares.Upgrade.sol
```

### Running Specific Test Functions
```bash
# Run a specific test function
forge test --match-path test/kpkShares.Main.sol --match-test testCompleteDepositToRedeemWorkflow

# Run tests matching a pattern (--match-test takes a regex)
forge test --match-path test/kpkShares.Main.sol --match-test "testUpgrade"
```

## 🔧 Test Organization Benefits

### 1. **Logical Separation**
- Each domain has its own test file with focused responsibility
- Easy to locate tests for specific functionality
- Clear boundaries between different contract features

### 2. **Maintainability**
- Smaller, focused files are easier to maintain
- Changes to one domain don't affect others
- Clear separation of concerns

### 3. **Readability**
- Tests are organized by functionality
- Easy to understand what each test file covers
- Consistent structure across all domains

### 4. **Reusability**
- Base contract provides shared infrastructure
- Helper functions can be used across domains
- Common setup logic is centralized

### 5. **Coverage Tracking**
- Can run tests by domain to identify coverage gaps
- Easy to add new tests to specific domains
- Clear organization makes coverage analysis simpler

## 📁 File Descriptions

### `kpkShares.TestBase.sol`
- **Purpose**: Shared infrastructure and helper functions
- **Contains**: Setup logic, mock deployments, utility functions, constants
- **Inherits**: Forge's `Test` for common testing utilities

### `kpkShares.Initialization.sol`
- **Purpose**: Contract initialization and constructor validation
- **Tests**: Parameter validation, state initialization, role assignment
- **Coverage**: Constructor branches, initialization logic

### `kpkShares.Subscriptions.sol`
- **Purpose**: Subscription request functionality
- **Tests**: Request creation, processing, updates, cancellations
- **Coverage**: Subscription-related functions and edge cases

### `kpkShares.Redemptions.sol`
- **Purpose**: Redemption request functionality
- **Tests**: Request creation, processing, updates, cancellations
- **Coverage**: Redemption-related functions and edge cases

### `kpkShares.Fees.sol`
- **Purpose**: Fee calculation and management
- **Tests**: Management fees, redemption fees, performance fees
- **Coverage**: Fee-related functions and calculations

### `kpkShares.Assets.sol`
- **Purpose**: Asset approval and management
- **Tests**: Asset approval, removal, validation, decimals
- **Coverage**: Asset management functions and edge cases

### `kpkShares.Admin.sol`
- **Purpose**: Administrative functions and role management
- **Tests**: TTL settings, role grants, ownership transfers
- **Coverage**: Admin functions and authorization

### `kpkShares.Integration.sol`
- **Purpose**: Complex workflows and cross-domain scenarios
- **Tests**: End-to-end workflows, error recovery, stress tests
- **Coverage**: Integration scenarios and edge cases

### `kpkShares.Upgrade.sol`
- **Purpose**: Contract upgrade functionality
- **Tests**: UUPS proxy upgrades, state preservation, security
- **Coverage**: Upgrade-related functions and security

### `kpkShares.Main.sol`
- **Purpose**: Entry point for the core domains and cross-domain tests
- **Tests**: Integration between the core domains, helper function validation
- **Coverage**: Ensures the core domains work together correctly

## 🧪 Adding New Tests

### To a Specific Domain
1. Open the appropriate domain test file (e.g., `kpkShares.Subscriptions.sol`)
2. Add your test function in the appropriate section
3. Use the existing helper functions from the base contract
4. Follow the existing naming convention (`testFunctionName`)

### To a New Domain
1. Create a new file following the naming convention (`kpkShares.NewDomain.sol`)
2. Inherit from `kpkSharesTestBase`
3. Add the new domain to `kpkShares.Main.sol`
4. Follow the existing structure and documentation patterns

### Helper Functions
1. Add new helper functions to `kpkShares.TestBase.sol`
2. Make them `internal` for use by child contracts
3. Document their purpose and parameters
4. Ensure they follow the existing naming convention

## 📊 Coverage Analysis

Coverage is produced with Foundry's built-in `forge coverage`.

### Generate a Coverage Report
```bash
# Summary table in the terminal, for the whole suite
forge coverage

# Generate an lcov report
forge coverage --report lcov
```

### Coverage Metrics Explained

`forge coverage` reports the following metrics:

1. **Line Coverage**: Percentage of code lines that have been executed
2. **Statement Coverage**: Percentage of statements that have been executed
3. **Branch Coverage**: Percentage of conditional branches that have been tested
4. **Function Coverage**: Percentage of functions that have been called during testing

### By Domain
```bash
# Check coverage for specific domains
forge coverage --match-path test/kpkShares.Subscriptions.sol
forge coverage --match-path test/kpkShares.Fees.sol
```

### Overall Coverage
```bash
# Check coverage for the entire test suite
forge coverage --match-path test/kpkShares.Main.sol
```

### Coverage Reports
- Coverage reports will show which domains have gaps
- Easy to identify missing test coverage by functionality
- Clear organization makes it simple to add missing tests

## 🔍 Troubleshooting

### Common Issues
1. **Import Errors**: Ensure all domain files are properly imported in `kpkShares.Main.sol`
2. **Helper Function Errors**: Check that helper functions are properly defined in the base contract
3. **Setup Issues**: Verify that the base contract setup is working correctly

### Coverage Analysis Issues
1. **Missing lcov.info**: Run `forge coverage --report lcov` to generate coverage data
2. **Stack-too-deep errors**: Run `forge coverage --ir-minimum` if the build fails during instrumentation
3. **Working Directory**: Ensure you're running commands from the project root directory

### Debugging
1. Run individual domain tests to isolate issues
2. Check the base contract for common setup problems
3. Use `forge test -vvvv` for detailed output

## 📈 Future Improvements

### Potential Enhancements
1. **Test Categories**: Add more granular categorization within domains
2. **Performance Tests**: Add dedicated performance testing domain
3. **Gas Tests**: Expand the existing gas tests in `kpkShares.GasTest.sol`
4. **Fuzzing**: Integrate fuzzing tests into the domain structure

### Coverage Analysis Enhancements
1. **Automated Coverage Tracking**: Integrate with CI/CD for automated coverage reporting
2. **Coverage Trends**: Track coverage improvements over time
3. **Coverage Thresholds**: Set minimum coverage requirements for PRs
4. **Coverage Visualization**: Generate HTML coverage reports with better visualization

### Maintenance
1. **Regular Reviews**: Periodically review test organization for improvements
2. **Documentation Updates**: Keep this README updated with changes
3. **Coverage Monitoring**: Track coverage improvements over time

---

This organization provides a clean, maintainable, and scalable test structure that makes it easy to add new tests, maintain existing ones, and understand the overall test coverage for the `kpkShares` contract. Foundry's built-in `forge coverage` provides insights into test coverage and helps identify areas for improvement.
