// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {
  FHE,
  euint16,
  euint32,
  externalEuint16,
  externalEuint32
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedCharacterProgress is ZamaEthereumConfig {
  // -------- Ownable --------
  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // -------- Simple nonReentrant guard (future-proof for payable flows) --------
  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------------------------------------------------------------------------
  // Encrypted character stats
  //
  // We model a character as:
  // - eXp:     encrypted XP (euint32)
  // - eSkill1: encrypted skill 1 (euint16)
  // - eSkill2: encrypted skill 2 (euint16)
  // - eSkill3: encrypted skill 3 (euint16)
  // - eSkill4: encrypted skill 4 (euint16)
  //
  // All fields are opaque ciphertexts on-chain.
  // Only the player has decrypt rights via ACL + userDecrypt().
  // ---------------------------------------------------------------------------

  struct CharacterStats {
    bool exists;
    euint32 eXp;
    euint16 eSkill1;
    euint16 eSkill2;
    euint16 eSkill3;
    euint16 eSkill4;
  }

  // player => characterId => stats
  mapping(address => mapping(uint256 => CharacterStats)) private characters;

  event CharacterCreated(
    address indexed player,
    uint256 indexed characterId,
    bytes32 xpHandle,
    bytes32 skill1Handle,
    bytes32 skill2Handle,
    bytes32 skill3Handle,
    bytes32 skill4Handle
  );

  event CharacterUpdated(
    address indexed player,
    uint256 indexed characterId,
    bytes32 xpHandle,
    bytes32 skill1Handle,
    bytes32 skill2Handle,
    bytes32 skill3Handle,
    bytes32 skill4Handle
  );

  // ---------------------------------------------------------------------------
  // Character creation
  // ---------------------------------------------------------------------------

  /**
   * Create a new character with fully encrypted initial stats.
   *
   * Frontend flow (high-level):
   * 1) Off-chain, call relayer.createEncryptedInput(contractAddress, player).
   * 2) Add fields in this exact order:
   *      - add32(initialXp)
   *      - add16(initialSkill1)
   *      - add16(initialSkill2)
   *      - add16(initialSkill3)
   *      - add16(initialSkill4)
   * 3) Call encrypt() to get { handles, inputProof }.
   * 4) Map handles[0..4] to:
   *      - encXp        -> externalEuint32
   *      - encSkill1/2/3/4 -> externalEuint16
   *    Pass the same inputProof to this function.
   *
   * The contract:
   * - Imports the ciphertexts using FHE.fromExternal.
   * - Grants itself long-term ACL (FHE.allowThis).
   * - Grants the player decrypt rights (FHE.allow(..., msg.sender)).
   */
  function createCharacter(
    uint256 characterId,
    externalEuint32 encXp,
    externalEuint16 encSkill1,
    externalEuint16 encSkill2,
    externalEuint16 encSkill3,
    externalEuint16 encSkill4,
    bytes calldata proof
  ) external nonReentrant {
    CharacterStats storage C = characters[msg.sender][characterId];
    require(!C.exists, "Character already exists");

    // Ingest all encrypted fields from the same proof batched by the gateway
    euint32 eXp = FHE.fromExternal(encXp, proof);
    euint16 eSkill1 = FHE.fromExternal(encSkill1, proof);
    euint16 eSkill2 = FHE.fromExternal(encSkill2, proof);
    euint16 eSkill3 = FHE.fromExternal(encSkill3, proof);
    euint16 eSkill4 = FHE.fromExternal(encSkill4, proof);

    // Allow this contract to perform future FHE operations on these ciphertexts
    FHE.allowThis(eXp);
    FHE.allowThis(eSkill1);
    FHE.allowThis(eSkill2);
    FHE.allowThis(eSkill3);
    FHE.allowThis(eSkill4);

    // Allow the player to decrypt their own stats via userDecrypt
    FHE.allow(eXp, msg.sender);
    FHE.allow(eSkill1, msg.sender);
    FHE.allow(eSkill2, msg.sender);
    FHE.allow(eSkill3, msg.sender);
    FHE.allow(eSkill4, msg.sender);

    C.exists = true;
    C.eXp = eXp;
    C.eSkill1 = eSkill1;
    C.eSkill2 = eSkill2;
    C.eSkill3 = eSkill3;
    C.eSkill4 = eSkill4;

    emit CharacterCreated(
      msg.sender,
      characterId,
      FHE.toBytes32(C.eXp),
      FHE.toBytes32(C.eSkill1),
      FHE.toBytes32(C.eSkill2),
      FHE.toBytes32(C.eSkill3),
      FHE.toBytes32(C.eSkill4)
    );
  }

  // ---------------------------------------------------------------------------
  // Character progression (encrypted updates)
  // ---------------------------------------------------------------------------

  /**
   * Apply encrypted XP and skill increments to an existing character.
   *
   * Frontend flow (high-level):
   * 1) Off-chain, compute increments (deltaXp, deltaSkill1..4).
   * 2) Encrypt them with relayer.createEncryptedInput in this order:
   *      - add32(deltaXp)
   *      - add16(deltaSkill1)
   *      - add16(deltaSkill2)
   *      - add16(deltaSkill3)
   *      - add16(deltaSkill4)
   * 3) Call encrypt() to get { handles, inputProof }.
   * 4) Map handles[0..4] to encDeltaXp / encDeltaSkill* and call this function.
   *
   * Notes:
   * - All updates happen under FHE using FHE.add.
   * - The contract never sees plaintext deltas or resulting stats.
   */
  function updateCharacterProgress(
    uint256 characterId,
    externalEuint32 encDeltaXp,
    externalEuint16 encDeltaSkill1,
    externalEuint16 encDeltaSkill2,
    externalEuint16 encDeltaSkill3,
    externalEuint16 encDeltaSkill4,
    bytes calldata proof
  ) external nonReentrant {
    CharacterStats storage C = characters[msg.sender][characterId];
    require(C.exists, "Character does not exist");

    // Ingest encrypted increments
    euint32 eDeltaXp = FHE.fromExternal(encDeltaXp, proof);
    euint16 eDeltaSkill1 = FHE.fromExternal(encDeltaSkill1, proof);
    euint16 eDeltaSkill2 = FHE.fromExternal(encDeltaSkill2, proof);
    euint16 eDeltaSkill3 = FHE.fromExternal(encDeltaSkill3, proof);
    euint16 eDeltaSkill4 = FHE.fromExternal(encDeltaSkill4, proof);

    // Contract needs rights to operate on increments as well
    FHE.allowThis(eDeltaXp);
    FHE.allowThis(eDeltaSkill1);
    FHE.allowThis(eDeltaSkill2);
    FHE.allowThis(eDeltaSkill3);
    FHE.allowThis(eDeltaSkill4);

    // Add encrypted deltas to encrypted state
    C.eXp = FHE.add(C.eXp, eDeltaXp);
    C.eSkill1 = FHE.add(C.eSkill1, eDeltaSkill1);
    C.eSkill2 = FHE.add(C.eSkill2, eDeltaSkill2);
    C.eSkill3 = FHE.add(C.eSkill3, eDeltaSkill3);
    C.eSkill4 = FHE.add(C.eSkill4, eDeltaSkill4);

    // Ensure ACL stays correct for the updated ciphertexts
    FHE.allowThis(C.eXp);
    FHE.allowThis(C.eSkill1);
    FHE.allowThis(C.eSkill2);
    FHE.allowThis(C.eSkill3);
    FHE.allowThis(C.eSkill4);

    FHE.allow(C.eXp, msg.sender);
    FHE.allow(C.eSkill1, msg.sender);
    FHE.allow(C.eSkill2, msg.sender);
    FHE.allow(C.eSkill3, msg.sender);
    FHE.allow(C.eSkill4, msg.sender);

    emit CharacterUpdated(
      msg.sender,
      characterId,
      FHE.toBytes32(C.eXp),
      FHE.toBytes32(C.eSkill1),
      FHE.toBytes32(C.eSkill2),
      FHE.toBytes32(C.eSkill3),
      FHE.toBytes32(C.eSkill4)
    );
  }

  // ---------------------------------------------------------------------------
  // Getters (handles only, no FHE ops)
  // ---------------------------------------------------------------------------

  /**
   * Lightweight metadata getter (no FHE operations).
   * Lets frontends check if a character exists without exposing stats.
   */
  function getCharacterMeta(address player, uint256 characterId)
    external
    view
    returns (bool exists)
  {
    CharacterStats storage C = characters[player][characterId];
    return C.exists;
  }

  /**
   * Returns encrypted handles for the caller's character stats:
   * - xpHandle:      encrypted XP (userDecrypt only).
   * - skill1Handle:  encrypted skill 1 (userDecrypt only).
   * - skill2Handle:  encrypted skill 2 (userDecrypt only).
   * - skill3Handle:  encrypted skill 3 (userDecrypt only).
   * - skill4Handle:  encrypted skill 4 (userDecrypt only).
   *
   * The caller can pass these handles to the Relayer SDK's userDecrypt(...)
   * along with their EIP-712 signature to retrieve plaintext values locally.
   */
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
    )
  {
    CharacterStats storage C = characters[msg.sender][characterId];
    return (
      FHE.toBytes32(C.eXp),
      FHE.toBytes32(C.eSkill1),
      FHE.toBytes32(C.eSkill2),
      FHE.toBytes32(C.eSkill3),
      FHE.toBytes32(C.eSkill4),
      C.exists
    );
  }

  /**
   * (Optional admin helper)
   * Expose encrypted XP handle for a given player/character.
   * This does NOT allow the owner to decrypt; it just returns a handle.
   * Only parties with ACL rights can actually decrypt it via userDecrypt.
   *
   * Included as an example of owner-only analytics tooling.
   */
  function getCharacterXpHandleForOwner(address player, uint256 characterId)
    external
    view
    onlyOwner
    returns (bytes32 xpHandle, bool exists)
  {
    CharacterStats storage C = characters[player][characterId];
    return (FHE.toBytes32(C.eXp), C.exists);
  }
}
