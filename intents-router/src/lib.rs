// Library entry point — exposes all modules so integration tests
// in tests/ can access internal types without duplication.
pub mod abi;
pub mod config;
pub mod error;
pub mod evm;
pub mod near;
pub mod persistence;
pub mod router;
pub mod state;
