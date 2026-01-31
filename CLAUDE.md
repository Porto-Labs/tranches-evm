# Project Instructions

## General

- Use Foundry for development, testing, and deployment
- Dependencies are managed via Foundry git submodules in `lib/`
- Always keep PROGRESS.md up-to-date as the bootstrap entrypoint for context
- Check and edit PROGRESS.md before and after completing a milestone or task
- Only track meaningful features in PROGRESS.md (not bugfixes, refactorings, or cleanup)
- We use 1e18 decimal precision within the project. If an external integration returns different precision it should be converted straight away to 1e18 precision.
- Do not use WAD terminology
- Do not add in-line comments. Code should be self explanatory. Code + natspec + intuitive variable naming should be enough for clean code.

---

## Project Structure

```
src/           - Production contracts
test/          - Foundry tests (.t.sol)
test/mocks/    - Mock contracts for testing
lib/           - Git submodule dependencies (forge-std, OpenZeppelin, Chainlink, Uniswap)
script/        - Deployment scripts
```

---

## Commands

```bash
forge build              # Compile contracts
forge test               # Run all tests
forge test -vvv          # Run tests with verbose output
forge test --match-test testFunctionName  # Run specific test
forge test --match-contract ContractName  # Run tests in specific contract
forge coverage --ir-minimum  # Generate coverage report (--ir-minimum prevents stack too deep errors)
forge fmt                # Format Solidity files
```

---

## Test Writing Guidelines

### Test File Organization

Separate test files by business logic domain:

```
test/
├── PortoDeposit.t.sol         # Deposit/withdrawal logic
├── PortoBorrow.t.sol          # Minting/borrowing logic
├── PortoLiquidation.t.sol     # Liquidation mechanism
├── PortoRepay.t.sol           # Debt repayment logic
├── Invariants/
│   └── BaseInvariant.t.sol
└── mocks/
```

### Test Type Decision Tree

```
What are you testing?
│
├─► Single function behavior → Unit Test (test_)
│   └─► With random inputs → Fuzz Test (testFuzz_)
│
├─► Protocol-wide property → Invariant Test (invariant_)
│   └─► "X should always be true"
│
└─► Real contract interaction → Fork Test (testFork_)
```

### Revert Reasons Checklist

For each function, consider testing these revert scenarios:

- **Access control** - Unauthorized caller rejected
- **Zero address** - Invalid address(0) input rejected
- **Zero amount** - Invalid zero value rejected
- **Not found** - Resource/entity doesn't exist
- **Invalid state** - Wrong state for operation
- **Already exists** - Duplicate creation rejected
- **Insufficient balance** - Not enough funds

### Naming Conventions

```solidity
function test_Deposit_UpdatesBalances() public {}
function test_RevertWhen_CallerNotOwner() public {}
function testFuzz_Withdraw(uint256 amount) public {}
function testFork_SwapOnUniswap() public {}
function invariant_TotalSupplyMatchesBalances() public {}
```

### Test Structure

- Happy paths FIRST, revert cases LAST
- Test both events AND state changes
- One logical behavior per test

```solidity
function test_Deposit_Success() public {
    uint256 amount = 1e18;

    vm.expectEmit(true, false, false, true);
    emit Deposited(user, amount);

    vm.prank(user);
    contract.deposit(amount);

    assertEq(contract.balanceOf(user), amount);
}

function test_RevertWhen_ZeroAmount() public {
    vm.expectRevert(abi.encodeWithSelector(InvalidAmount.selector));
    contract.deposit(0);
}
```

### Fuzz Testing

```solidity
function testFuzz_Deposit(uint256 amount) public {
    amount = bound(amount, 1, type(uint128).max);

    vm.prank(user);
    contract.deposit(amount);

    assertEq(contract.balanceOf(user), amount);
}
```

### Invariant Testing

```solidity
contract InvariantTest is Test {
  Handler handler;

  function setUp() public {
    handler = new Handler(targetContract);
    targetContract(address(handler));
  }

  function invariant_BalancesMatchTotalSupply() public {
    assertEq(token.totalSupply(), handler.ghost_totalDeposited());
  }
}

contract Handler is Test {
  uint256 public ghost_totalDeposited;

  function deposit(uint256 amount) external {
    amount = bound(amount, 1, 1e28);
    target.deposit(amount);
    ghost_totalDeposited += amount;
  }
}
```

### Fork Testing

```solidity
function setUp() public {
  vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 18_000_000);
}
```

### Essential Cheatcodes

| Category   | Cheatcodes                                 |
| ---------- | ------------------------------------------ |
| Identity   | `prank`, `startPrank`, `stopPrank`         |
| State      | `deal`, `store`, `load`                    |
| Time       | `warp`, `roll`, `skip`                     |
| Assertions | `expectRevert`, `expectEmit`, `expectCall` |
| Fuzzing    | `bound`, `assume`                          |
| Addresses  | `makeAddr`, `makeAddrAndKey`               |

### Debugging

```bash
forge test -vv     # Show logs
forge test -vvv    # Show traces for failing tests
forge test -vvvv   # Show traces for all tests
forge test -vvvvv  # Show traces + setup
```
