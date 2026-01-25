# Test Writing Guidelines

## `describe` vs `context`

In Mocha, `describe` and `context` are aliases (functionally identical). The difference is semantic:

- **`describe`** - groups tests around a unit (contract, function)
- **`context`** - describes a scenario or state ("when X", "with valid input")

```typescript
describe("MyContract", function () {
  context("when valid data", function () { /* tests */ });
  context("when invalid data", function () { /* tests */ });
});
```

Either style is acceptable; consistency within a file matters more.

---

## Structure

```typescript
describe("ContractName", function () {
  // Shared variables
  let contract: Contract;
  let signers: Signer[];

  before(async function () {
    // Global setup - deploy contracts, get signers
    // Runs once before all tests in this describe block
  });

  afterEach(async function () {
    // Reset state between tests (via loadFixture or snapshot/restore)
  });

  context("functionName", function () {
    beforeEach(async function () {
      // Function-specific setup if needed
    });

    // 1. Happy path tests FIRST
    it("Should do X when Y", async function () { ... });
    it("Should handle edge case Z", async function () { ... });

    // 2. Revert cases LAST - grouped in dedicated context
    context("Revert reasons", function () {
      it("Reverts when invalid input", async function () { ... });
      it("Reverts when unauthorized", async function () { ... });
    });
  });
});
```

## Key Principles

1. **Happy paths first** - Test successful scenarios at the top of each function context
2. **"Revert reasons" at end** - Group all error cases in a dedicated nested context
3. **Test events AND state** - Verify both emitted events and resulting state changes
4. **Use `loadFixture`** - For setup/reset to enable snapshot/restore
5. **One assertion focus per test** - Each test should verify one logical behavior

## Assertion Patterns

```typescript
// Events - verify emission and arguments
await expect(tx).to.emit(contract, "EventName").withArgs(arg1, arg2);

// State changes - verify before and after
expect(await contract.getValue()).to.equal(expected);

// Custom errors with arguments
await expect(tx)
  .to.be.revertedWithCustomError(contract, "ErrorName")
  .withArgs(expected1, expected2);

// Access control errors
await expect(contract.connect(unauthorized).method())
  .to.be.revertedWithCustomError(accessControl, "AccessControlUnauthorizedAccount");

// Panic codes (overflow, division by zero, etc.)
await expect(tx).to.be.revertedWithPanic("0x12"); // division by zero
await expect(tx).to.be.revertedWithPanic("0x32"); // array out of bounds

// Error strings
await expect(tx).to.be.revertedWith("Error message");
```

## Standard Revert Reasons Checklist

For each function, consider testing these common revert scenarios:

- [ ] **Pausable** - Function reverts when paused (if applicable)
- [ ] **Access control** - Unauthorized caller rejected
- [ ] **Zero address** - Invalid address(0) input rejected
- [ ] **Zero amount** - Invalid zero value rejected
- [ ] **Not found** - Resource/entity doesn't exist
- [ ] **Invalid state** - Wrong state for operation
- [ ] **Already exists** - Duplicate creation rejected
- [ ] **Expired/timeout** - Time-based constraints
- [ ] **Invalid signature** - Signature verification failures

## Test Naming Conventions

```typescript
// Happy path - describe expected behavior
it("Should transfer tokens to recipient", ...);
it("Emits Transfer event with correct arguments", ...);

// Revert cases - start with "Reverts when" or describe the constraint
it("Reverts when caller is not owner", ...);
it("Reverts when amount exceeds balance", ...);
```

## Fixture Pattern

```typescript
async function deployContractFixture() {
  const [owner, user1, user2] = await ethers.getSigners();
  const Contract = await ethers.getContractFactory("MyContract");
  const contract = await Contract.deploy();
  return { contract, owner, user1, user2 };
}

// Usage
beforeEach(async function () {
  const { contract, owner } = await loadFixture(deployContractFixture);
});
```

## Testing Both Events and State

Always verify both the emitted events AND the resulting state change:

```typescript
it("Should update balance and emit event", async function () {
  const tx = await contract.deposit(amount);

  // Verify event
  await expect(tx)
    .to.emit(contract, "Deposited")
    .withArgs(user.address, amount);

  // Verify state
  expect(await contract.balanceOf(user.address)).to.equal(amount);
});
```
