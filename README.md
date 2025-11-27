# Encrypted Character Progress

Private on-chain character growth powered by **Zama FHEVM**.
XP and skills are stored as encrypted ciphertexts on Ethereum Sepolia – only the player can decrypt their clear values locally via the Relayer SDK.

> **Concept:**
> Upgrade your game character on-chain without ever revealing raw XP or skill numbers. The contract sees only encrypted inputs and performs all updates under Fully Homomorphic Encryption (FHE).

---

## ✨ Overview

This project demonstrates how to build **privacy-preserving game progression** using Zama’s FHEVM:

* Each **character** is identified by a `characterId` (1, 2, 3, …) per wallet.
* For every character, the contract stores:

  * Encrypted **XP** (`euint32`)
  * Encrypted **four skill stats** (`euint16[4]`)
* Players:

  * Initialize a character with encrypted stats (`createCharacter`)
  * Apply encrypted XP/skill deltas (`updateCharacterProgress`)
  * Privately decrypt their stats via **Relayer `userDecrypt`** on the frontend.
* The chain never learns the underlying XP/skill numbers — only ciphertexts and handles.

---

## 🧠 FHE Model & Game Logic

### Data model

For each player address and `characterId`, the contract (conceptually) keeps:

* `euint32 eXp` – encrypted XP
* `euint16 eSkill1`
* `euint16 eSkill2`
* `euint16 eSkill3`
* `euint16 eSkill4`
* `bool exists` – whether this character has been initialized

All of these encrypted values live in FHEVM memory and are only manipulated using the Zama FHE library.

### Key operations

1. **Create character (encrypted init)**

   ```solidity
   function createCharacter(
     uint256 characterId,
     externalEuint32 encXp,
     externalEuint16 encSkill1,
     externalEuint16 encSkill2,
     externalEuint16 encSkill3,
     externalEuint16 encSkill4,
     bytes calldata proof
   ) external;
   ```

   High level:

   * Frontend encrypts initial `xp` + `skill[4]` via Relayer SDK.
   * Gateway returns encrypted handles + proof.
   * Contract ingests them with `FHE.fromExternal(...)` and stores as `euint32` / `euint16` values.
   * Access control: `FHE.allowThis` for the contract, `FHE.allow(..., msg.sender)` so only the player can decrypt later.

2. **Apply encrypted progress (XP & skills deltas)**

   ```solidity
   function updateCharacterProgress(
     uint256 characterId,
     externalEuint32 encDeltaXp,
     externalEuint16 encDeltaSkill1,
     externalEuint16 encDeltaSkill2,
     externalEuint16 encDeltaSkill3,
     externalEuint16 encDeltaSkill4,
     bytes calldata proof
   ) external;
   ```

   Logic (conceptual, under FHE):

   ```solidity
   euint32 eDeltaXp = FHE.fromExternal(encDeltaXp, proof);
   euint16 eDeltaS1 = FHE.fromExternal(encDeltaSkill1, proof);
   ...
   // All FHE ops:
   S.eXp      = FHE.add(S.eXp, eDeltaXp);
   S.eSkill1  = FHE.add(S.eSkill1, eDeltaS1);
   S.eSkill2  = FHE.add(S.eSkill2, eDeltaS2);
   S.eSkill3  = FHE.add(S.eSkill3, eDeltaS3);
   S.eSkill4  = FHE.add(S.eSkill4, eDeltaS4);
   ```

   Constraints:

   * Deltas are **non-negative** (no refunds).
   * All arithmetic happens on ciphertexts, without revealing numbers.

3. **View handles for decryption**

   ```solidity
   function getMyCharacterHandles(uint256 characterId)
     external
     view
     returns (
       bytes32 xpHandle,
       bytes32 skill1Handle,
       bytes32 skill2Handle,
       bytes32 skill3Handle,
       bytes32 skill4Handle,
       bool exists
     );
   ```

   The frontend uses these handles + Relayer SDK `userDecrypt` to recover clear XP/skills **locally only**.

4. **Meta & owner helper**

   * `getCharacterMeta(player, characterId) -> bool exists`
   * `getCharacterXpHandleForOwner(player, characterId)` – optional hook if the game owner wants to run off-chain analytics with proper ACL.

---

## 🔐 Privacy & FHE Flow

### End-to-end pipeline

1. **Encrypt on the frontend**

   ```ts
   const buf = relayer.createEncryptedInput(CONTRACT_ADDRESS, userAddress);
   buf.add32(xp);
   buf.add16(skill1);
   buf.add16(skill2);
   buf.add16(skill3);
   buf.add16(skill4);

   const { handles, inputProof } = await buf.encrypt();
   // send to createCharacter / updateCharacterProgress
   ```

2. **Ingest & update on-chain (contract)**

   ```solidity
   euint32 eXp = FHE.fromExternal(encXp, proof);
   euint16 eS1 = FHE.fromExternal(encSkill1, proof);
   // ... store and update under encryption
   ```

3. **Expose only handles**

   ```solidity
   function getMyCharacterHandles(uint256 characterId)
     external
     view
     returns (bytes32, bytes32, bytes32, bytes32, bytes32, bool);
   ```

4. **Decrypt locally (frontend)**

   ```ts
   const { out, pairs } = await relayer.userDecrypt(...);
   // Map out -> handles, then show clear values in the UI only.
   ```

At no point does the contract learn raw XP/skill numbers.

---

## 🕹 Frontend UX

The sample frontend is a single-page HTML/JS app using **ethers v6** and Zama’s **Relayer SDK** via CDN.

### Main sections

1. **Hero & connection panel**

   * Shows project title and short explanation.
   * Wallet connect button (MetaMask / EIP-1193).
   * Displays current network (Sepolia), user address and contract address.
   * Shows whether HTTPS is being used (recommended for WASM worker & userDecrypt).

2. **Character slot selector**

   * Choose the `characterId` to work with.
   * Quick buttons for ID `#1` and `#2`.
   * "Check character on-chain" button calls `getCharacterMeta` and shows whether encrypted stats exist.

3. **Create encrypted character**

   * Inputs:

     * Initial XP (`uint32`)
     * Skill I / II / III / IV (`uint16` each)
   * Flow:

     * Encrypts all values client-side via Relayer SDK (`createEncryptedInput`).
     * Sends handles + proof to `createCharacter`.
     * Shows tx hash and status.

4. **Apply encrypted progress**

   * Inputs:

     * XP delta (`uint32`)
     * Skill I–IV deltas (`uint16` each)
   * Flow:

     * Encrypts deltas via Relayer SDK.
     * Calls `updateCharacterProgress` with encrypted deltas.
     * All XP/skills are updated fully under FHE.

5. **Decrypt my encrypted stats**

   * Button: `Decrypt stats for this ID`.
   * Steps:

     * Fetches handles from `getMyCharacterHandles(characterId)`.
     * Builds a `userDecrypt` request (short-lived keypair + EIP-712 typed data).
     * Displays clear XP & skill values **only in the browser** (never sent on-chain).
   * If no character exists yet, shows a clear warning.

### userDecrypt / BigInt handling

The frontend follows best practices for Zama Relayer responses:

* Uses a `safeStringify` helper to avoid `BigInt` JSON issues in logs.
* Normalizes `userDecrypt` results with a dedicated helper so values of types `bigint | number | boolean | string` are handled safely.
* Never calls `JSON.stringify` directly on objects containing `BigInt` without the custom replacer.

---

## 🧱 Project Structure

A minimal repo structure might look like this:

```text
root/
├─ contracts/
│  └─ EncryptedCharacterProgress.sol
├─ frontend/
│  └─ index.html          # Single-page app using ethers + Relayer SDK CDN
├─ hardhat.config.ts      # Or foundry / other tooling
├─ package.json
├─ README.md              # This file
└─ scripts/
   └─ deploy.ts           # Example deploy script (optional)
```

You can adapt the layout to your favorite stack (Hardhat, Foundry, wagmi, etc.).

---

## 🚀 Getting Started

### 1. Clone & install

```bash
git clone &lt;this-repo-url&gt;
cd &lt;this-repo&gt;

# optional – for solidity tooling
npm install
```

### 2. Deploy contract (if needed)

If the contract is not already deployed, use your preferred tool (Hardhat, Foundry) with Zama FHEVM-enabled Sepolia RPC.

Example (pseudo):

```ts
const factory = await ethers.getContractFactory("EncryptedCharacterProgress");
const contract = await factory.deploy();
await contract.deployed();
console.log("Contract:", contract.address);
```

Update the **frontend** constant:

```js
const CONTRACT_ADDRESS = "0x..."; // deployed address
```

### 3. Run the frontend

Simplest: serve `frontend/index.html` over HTTPS (or via the provided dev proxy setup) so `userDecrypt` and WASM workers are happy.

Examples:

```bash
# minimal static server
npx serve frontend

# or any other HTTPS-capable dev server
```

Open the app in your browser, connect your Sepolia wallet, and start creating encrypted characters.

---

## ⚙️ Tech Stack

* **Solidity** `^0.8.24`
* **Zama FHEVM** Solidity library
* **Zama Relayer SDK (JS)** via CDN
* **Ethers v6** (BrowserProvider / Contract)
* **Ethereum Sepolia** as the target network

---

## 🧭 Design goals

* Demonstrate a **game-like**, privacy-preserving use case.
* Keep the contract **FHE-correct**: no FHE ops in view/pure functions; only handles returned.
* Showcase **frontend patterns** for:

  * Relayer `createEncryptedInput`
  * `userDecrypt` with EIP-712
  * Safe handling of `BigInt` / mixed-type decrypt responses.

---

## 🔮 Ideas for Extensions

* Multiple character classes with different skill layouts.
* Encrypted level thresholds (XP → level) evaluated fully under FHE.
* Encrypted leaderboard logic (e.g., comparing characters’ XP privately).
* Off-chain analytics via `getCharacterXpHandleForOwner` with strict ACL policies.

---

## Disclaimer

This project is a **demo** and not production-ready.
Before using it in a real game or mainnet environment, you should:

* Audit the smart contracts.
* Review UX, error handling, and edge cases.
* Validate performance and FHE cost on your
