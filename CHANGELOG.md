# Changelog

## [v0.5.0] - 2024-03-27

### Added

- Support for `key=value` format in VM/container descriptions for Traefik labels
- Better error handling and debug logging for troubleshooting
- IP address discovery for containers
- Proper configuration generation from VM/container labels

### Fixed

- Empty configuration issue when using `key=value` format
- Extended poll interval from 5s to 30s to reduce API load
- Package structure to match Traefik plugin standards

### Documentation

- Improved README with clear labeling instructions
- Added troubleshooting section
- Added examples for different routing scenarios

## [v0.4.5] - 2024-03-21

### Added

- Support for Proxmox VE 8.0 and newer versions
- Improved error handling and logging throughout the plugin
- Better configuration validation with detailed error messages
- Initial configuration update before starting the polling interval
- Panic recovery in provider goroutines for better stability
- Minimum poll interval check (5 seconds) to prevent API overload
- Detailed logging for VM and container scanning operations

### Changed

- Default poll interval increased from 5s to 30s to reduce API load
- Improved error messages with proper error wrapping
- Better organization of code structure following Traefik plugin best practices
- Enhanced configuration validation with more specific error messages
- Updated logging messages to be more descriptive and informative
- Improved error handling in goroutines with proper context cancellation

### Fixed

- Potential race conditions in configuration updates
- Memory leaks in long-running operations
- Error handling in network interface scanning
- Configuration validation for required fields
- Proper cleanup of resources in Stop() method

### Security

- Added validation for API endpoint and token configuration
- Improved SSL validation handling
- Better error handling for API authentication failures

### Documentation

- Updated README with improved configuration examples
- Added more detailed logging information
- Better documentation of configuration options

### Dependencies

- Updated to use latest Traefik plugin interfaces
- Improved compatibility with newer Go versions

### Notes

- This version requires Traefik v2.0 or newer
- The plugin now follows standard Traefik plugin naming conventions
- Improved stability and reliability for production environments 