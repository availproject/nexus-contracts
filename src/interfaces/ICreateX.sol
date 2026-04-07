// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal interface for the CreateX deterministic deployer factory.
///         Canonical address: 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
interface ICreateX {
    /// @notice Deploys a contract via CREATE3 with a caller-controlled salt.
    ///         The resulting address depends only on (deployer, salt), not on initcode.
    /// @param salt            A 32-byte salt. The first 20 bytes can optionally encode
    ///                        a guard address (if non-zero, msg.sender must match).
    /// @param initCode        The full creation bytecode (constructor + args).
    /// @return deployed       The deterministic address of the new contract.
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address deployed);

    /// @notice Computes the CREATE3 address for a given deployer and salt
    ///         without deploying.
    function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address computed);

    /// @notice Computes the CREATE3 address when called by msg.sender.
    function computeCreate3Address(bytes32 salt) external view returns (address computed);

    /// @notice Deploys a contract via CREATE2 with the given salt and init code.
    ///         The resulting address depends on (deployer, salt, initCodeHash).
    /// @param salt            A 32-byte salt.
    /// @param initCode        The full creation bytecode (constructor + args).
    /// @return deployed       The deterministic address of the new contract.
    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address deployed);

    /// @notice Computes the CREATE2 address for the given salt and init code hash
    ///         when called by msg.sender.
    function computeCreate2Address(bytes32 salt, bytes32 initCodeHash) external view returns (address computed);
}
