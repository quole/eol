#======================================================================
#                     staging.rb
# Environment specific settings for the Staging environment
#
# Settings specified here will override those in config/environment.rb.
# Configuration files are loaded in the following order with the settings
# in each file overriding the settings in prior files
#
# 1) config/environment.rb
# 2) config/environments/[RAILS_ENV].rb
# 3) config/environments/[RAILS_ENV]_eol_org.rb
# 4) config/environment_eol_org.rb
#======================================================================

# Use a different logger for distributed setups
# config.logger = SyslogLogger.new


# Full error reports are disabled and caching is turned on
config.action_controller.consider_all_requests_local = false
config.action_controller.perform_caching             = true
config.action_view.debug_rjs                         = false

# Disable delivery errors, bad email addresses will be ignored
config.action_mailer.raise_delivery_errors = false

# Code is not reloaded between requests
# NOTE: is using Master DB connection, you *must* use config.cache_classes = true
config.cache_classes = true

# Set up the master database connection for writes using masochism plugin
# NOTE: for this to work, you *must* also use config.cache_classes = true
# (default for production)
config.after_initialize do 
  ActiveReload::ConnectionProxy.setup_for ActiveReload::MasterDatabase, ActiveRecord::Base
  ActiveReload::ConnectionProxy.setup_for LoggingWriter, LoggingModel
  $PARENT_CLASS_MUST_USE_MASTER = ActiveReload::MasterDatabase
end
$LOGGING_READ_FROM_MASTER = true

config.log_level = :debug # :error

# set to true to force users to use SSL for the login and signup pages 
$USE_SSL_FOR_LOGIN = false

$ENABLED_SOCIAL_PLUGINS = [:facebook, :twitter, :google, :yahoo] # Enable social sharing on the site e.g. Facebook Like button, and login with Facebook

#This part of the code should stay at the bottom to ensure that www.eol.org - related settings override everything
begin
  require File.join(File.dirname(__FILE__), 'staging_eol_org')
rescue LoadError
  puts '*************WARNING: COULD NOT LOAD STAGING_EOL_ORG FILE***********************'
end


