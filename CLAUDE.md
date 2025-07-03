# PostgreSQL TDE Extension Development Environment

We're developing the **pg_tde** (Transparent Data Encryption) extension for PostgreSQL. This is a PostgreSQL extension that provides data-at-rest encryption, located in `contrib/pg_tde/`.

**Important**: This is the complete PostgreSQL source tree, but we only develop the `contrib/pg_tde/` extension. All other parts of the PostgreSQL codebase should be treated as read-only and external.

## Development Focus

- **Working Directory**: `contrib/pg_tde/` - Our active development area
- **Extension Version**: 1.0 (GA release)
- **Target PostgreSQL**: Percona Server for PostgreSQL 17
- **Architecture**: Custom access method (`tde_heap`) with encryption for tuples, WAL, and indexes

## Essential Commands

### Building and Testing
```bash
# Build the extension (from contrib/pg_tde/)
make installcheck

# Build with PGXS (for Percona Distribution)
make installcheck USE_PGXS=1

# Run specific SQL regression test
make installcheck REGRESS=test_name

# Run TAP tests
make check-tap
```

### Key Development Tools
```bash
# Change key provider utility
./pg_tde_change_key_provider

# Format code (run from PostgreSQL root)
pgindent --typedefs=src/tools/pgindent/typedefs.list contrib/pg_tde/

# Run single TAP test
prove t/basic.pl
```

## Core Architecture

### Key Components
- **Access Method**: `src/access/` - TDE tuple maps and WAL handling
- **Encryption Layer**: `src/encryption/` - AES and TDE encryption implementations  
- **Keyring System**: `src/keyring/` - File, Vault, and KMIP key management
- **Storage Manager**: `src/smgr/` - Custom storage manager integration
- **Catalog Functions**: `src/catalog/` - Key management catalog operations

### External Dependencies
- **libkmip**: `src/libkmip/` - KMIP protocol support (third-party)
- **libcurl**: Required for HTTP/HTTPS operations with external KMS
- **OpenSSL**: Required for cryptographic operations

## Testing Framework

### SQL Regression Tests (`sql/` directory)
Key test categories:
- `key_provider` - Key provider functionality
- `kmip_test` - KMIP integration
- `vault_v2_test` - HashiCorp Vault integration
- `change_access_method` - Access method switching
- `toast_decrypt` - TOAST decryption
- `partition_table` - Partitioned table encryption

### TAP Tests (`t/` directory)
- `basic.pl` - Basic functionality
- `crash_recovery.pl` - Crash recovery scenarios
- `replication.pl` - Replication with encryption
- `rotate_key.pl` - Key rotation procedures
- `wal_encrypt.pl` - WAL encryption verification

## Key Extension Files

- **Control File**: `pg_tde.control` - Extension metadata
- **SQL Definition**: `pg_tde--1.0.sql` - Extension SQL objects
- **Build Config**: `Makefile` (traditional), `meson.build` (modern)
- **Test Config**: `pg_tde.conf` - Test environment configuration

## Development Workflow

### Code Standards
- Follow PostgreSQL coding standards, as described in @PostgreSQL-Coding-Patterns.md
- Use pgindent for formatting with project-specific typedefs
- Include Jira issue numbers in branch names and commit messages
- Test changes locally before submitting

### Branch Structure
- **Main Branch**: `TDE_REL_17_STABLE` 
- **Current Branch**: `release-17.5.2`

### Key Requirements
- **Percona Server for PostgreSQL 17** - Only supported version
- **Extended APIs** - Requires extended Storage Manager and WAL APIs
- **Root/Postgres User** - Some operations require proper ownership
- **External Libraries** - libcurl, OpenSSL must be available

## Security Considerations

This extension provides transparent data encryption at rest. Key security aspects:
- Encryption uses AES algorithm
- Supports multiple key management systems (file, Vault, KMIP)
- WAL encryption for complete data-at-rest protection
- Principal key management through catalog functions

## Limitations

Current limitations to be aware of:
- Does not encrypt temporary files
- Does not encrypt statistics
- Experimental phase - API may change
- PostgreSQL 17 specific
