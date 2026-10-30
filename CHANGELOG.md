# Change Log

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org).

## [2.0.4] - 30-10-2026

### Changed
- Enforced HTTPS, disabled redirects, encoded account lookup values, and bounded HTTP request timeouts.
- Added bounded retries for transient GET failures, respecting Retry-After and the account action time budget. Writes are not automatically replayed.
- Indexed resource and permission-name lookups by code, and updated the resource index after successful writes.

## [2.0.1] - 28-07-2026

### Fixed
-   Removed finally blocks used for business logic (success determination now at end of try block)
-   Improved error handling with consistent $actionMessage context tracking across all scripts
-   Enhanced error reporting with $warningMessage variable to prevent duplicate Write-Warning statements
-   Added null check in Resolve-CAPP12Error function: `if ($null -ne $errorDetailsObject.error)`
-   Standardized "not found" error detection in permission revoke operations

### Changed
-   Minimized Write-Information statements (retained only for DryRun messages and essential logging)
-   Added result count logging to import scripts for better visibility
-   Improved error messages with contextual $actionMessage at each processing step

## [2.0.0] - 02-04-2026

### Major Update

This release represents a significant upgrade leveraging the newly available GET API endpoints in CAPP12.

### Added
-   Account and permission import scripts for synchronizing entitlements from CAPP12
-   Dynamic permission scripts for managing assignments, employments, and manager permissions (replacing static DepartmentManager resource and permissions in account create and update scripts)
-   Entitlement Import support for both accounts and permissions
-   Governance Reconciliation capabilities
-   Enhanced field descriptions in fieldMapping.json
-   GET API endpoints utilization for improved performance and data retrieval

### Changed
-   Refactored department and position creation logic to utilize GET endpoints for improved performance
-   Updated field mapping and account lifecycle handling
-   Redesigned permission architecture from static resource (DepartmentManager) to dynamic permission scripts

### Removed
-   DepartmentManager resource (replaced by the dynamic permission scripts for managers)

## [1.1.1] - 11-02-2025

Fixes:
-   Only one position was set/removed in the create/update script.
-   Resource data was not unique, resulting in unnecessary API calls.
-   The DepartmentManager resource script’s success flag was not set to false when actions failed in the foreach loop.

## [1.1.0] - 04-10-2024

Fixes after first implementation. Feature: removed enable/disable script

## [1.0.0] - 04-07-2024

This is the first official release of _HelloID-Conn-Prov-Target-CAPP12_. This release is based on template version _1.2.0_, with some features from the next release, 1.3?.x. The main feature added from the upcoming release is the integration of the Dryrun message into the main processing flow. Basically, the Dryrun switch has been moved as close as possible to the actual web requests.

### Added


### Changed

### Deprecated

### Removed