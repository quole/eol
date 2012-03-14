require 'uri'
begin
  require 'ruby-prof'
  puts "** Ruby Profiler loaded.  You can profile requests, now."
rescue MissingSourceFile
  # Do nothing, we don't care and we don't want anyone to freak out from a warning.
end
ContentPage # This fails to auto-load.  Could be a memcached thing, but easy enough to fix here.

class ApplicationController < ActionController::Base

  include ImageManipulation

  # Map custom exceptions to default response codes
  ActionController::Base.rescue_responses.update(
    'EOL::Exceptions::MustBeLoggedIn'                     => :unauthorized,
    'EOL::Exceptions::Pending'                            => :not_implemented,
    'EOL::Exceptions::SecurityViolation'                  => :forbidden,
    'OpenURI::HTTPError'                                  => :bad_request
  )

  filter_parameter_logging :password

  around_filter :profile

  before_filter :original_request_params # store unmodified copy of request params
  before_filter :global_warning
  before_filter :check_if_mobile if $ENABLE_MOBILE
  before_filter :clear_any_logged_in_session unless $ALLOW_USER_LOGINS
  before_filter :check_user_agreed_with_terms, :except => :error
  before_filter :set_locale

  prepend_before_filter :redirect_to_http_if_https
  prepend_before_filter :keep_home_page_fresh

  helper :all

  helper_method :logged_in?, :current_url, :current_user, :current_language, :return_to_url, :link_to_item

  # If recaptcha is not enabled, then override the method to always return true
  unless $ENABLE_RECAPTCHA
    def verify_recaptcha
      true
    end
  end

  def profile
    return yield if params[:profile].nil?
    return yield if ![ 'v2staging', 'v2staging_dev', 'v2staging_dev_cache', 'development', 'test'].include?(ENV['RAILS_ENV'])
    result = RubyProf.profile { yield }
    printer = RubyProf::GraphHtmlPrinter.new(result)
    out = StringIO.new
    printer.print(out, :min_percent=>0)
    response.body.replace out.string
  end


  # Continuously display a warning message.  This is used for things like "System Shutting down at 15 past" and the
  # like.  And, yes, if there's a "real" error, they miss this message.  So what?
  def global_warning
    # using SiteConfigutation over an environment constant DOES require a query for EVERY REQUEST
    # but the table is tiny (<5 rows right now) and the coloumn is indexed. But it also gives us the flexibility
    # to display or remove a message within seconds which I think is worth it
    # NOTE (!) if you set this value and don't see it change in 10 minutes, CHECK YOUR SLAVE LAG. It reads from slaves.
    # NOTE: if there is no row for global_site_warning, or the value is nil, we will cache the integer 1 so prevent
    # future lookups (when we check the cache and find a value of nil, it makes it look like the lookup was not cached)
    warning = $CACHE.fetch("application/global_site_warning", :expires_in => 10.minutes) do
      sco = SiteConfigurationOption.find_by_parameter('global_site_warning')
      (sco && sco.value) ? sco.value : 1
    end

    if warning && warning.class == String
      flash.now[:error] = warning
    end
  end

  def set_locale
    begin
      I18n.locale = current_language.iso_639_1
    rescue
      I18n.locale = 'en' # Yes, I am hard-coding that because I don't want an error from Language.  Ever.
    end
  end

  def allow_login_then_submit
    unless logged_in?
      # TODO: Can we delete the submitted data if the user doesn't login or signup?
      session[:submitted_data] = params
      # POST request should provide a submit_to URL so that we can redirect to the correct action with a GET.
      submit_to = params[:submit_to] || current_url
      respond_to do |format|
        format.html do
          flash[:notice] = I18n.t(:must_be_logged_in)
          redirect_to login_path(:return_to => submit_to)
        end
        format.js do
          render :partial => 'content/must_login', :layout => false, :locals => { :return_to => submit_to }
        end
      end
    end
  end

  def must_be_logged_in
    flash[:warning] =  I18n.t(:must_be_logged_in)
    session[:return_to] = request.url if params[:return_to].nil?
    redirect_to(login_path, :return_to => params[:return_to])
  end

  def view_helper_methods
    Helper.instance
  end

  class Helper
    include Singleton
    include TaxaHelper
    include ApplicationHelper
    include ActionView::Helpers::SanitizeHelper
  end

  # store a given URL (defaults to current) in case we need to redirect back later
  def store_location(url = url_for(:controller => controller_name, :action => action_name))
    # It's possible to create a redirection attack with a redirect to data: protocol... and possibly others, so:
    # Whitelisting redirection to our own site and relative paths.
    url = nil unless url =~ /\A([%2F\/]|#{root_url})/
    session[:return_to] = url
  end

  # retrieve url stored in session by store_location()
  # use redirect_back_or_default to specify a default url, do not add default here
  def return_to_url
    session[:return_to]
  end

  def referred_url
    request.referer
  end

  def current_url(remove_querystring = true)
    if remove_querystring
      current_url = URI.parse(request.url).path
    else
      request.url
    end
  end

  # Redirect to the URL stored by the most recent store_location call or to the passed default.
  def redirect_back_or_default(default_uri_or_active_record_instance = nil)
    back_uri = return_to_url || default_uri_or_active_record_instance
    store_location(nil)
    # If we've passed in an instance of active record, e.g. @user, we can redirect straight to it
    redirect_to back_uri and return if back_uri.is_a?(ActiveRecord::Base)
    back_uri = URI.parse(back_uri) rescue nil
    if back_uri.is_a?(URI::Generic) && back_uri.scheme.nil?
      # Assume it's a path and not a full URL, so make a full URL.
      back_uri = URI.parse("#{request.protocol}#{request.host_with_port}#{back_uri.to_s}")
    end
    # be sure we aren't returning to the login, register or logout page when logged in, or causing a loop
    if ! back_uri.nil? && %w( http ).include?(back_uri.scheme) &&
      (! logged_in? || [logout_url, login_url, new_user_url].select{|url| back_uri.to_s.include?(url)}.blank?)
      back_uri.query = nil if back_uri.query =~ /oauth_provider/i
      back_uri = back_uri.to_s
      back_uri = CGI.unescape(back_uri)
    else
      back_uri = root_url(:protocol => 'http')
    end
    redirect_to back_uri
  end

  # send user to the SSL version of the page (used in the account controller, can be used elsewhere)
  def redirect_to_ssl
    url_to_return = params[:return_to] ? CGI.unescape(params[:return_to]).strip : nil
    unless request.ssl? || local_request?
      if url_to_return && url_to_return[0...1] == '/'  #return to local url
        redirect_to :protocol => "https://", :return_to => url_to_return, :method => request.method, :status => :moved_permanently
      else
        redirect_to :protocol => "https://", :method => request.method, :status => :moved_permanently
      end
    end
  end

  def collected_errors(model_object)
    error_list = ''
    model_object.errors.each{|attr, msg| error_list += "#{attr} #{msg}," }
    return error_list.chomp(',')
  end

  # called to log and redirect a user to an external link
  def external_link

    url = params[:url]
    if url.nil?
      render :nothing => true
      return
    end

    ExternalLinkLog.log url, request, current_user

    redirect_to url

  end

  def redirect_to_http_if_https
    if request.ssl?
      redirect_to "http://" + request.host + request.request_uri, :status => :moved_permanently
    end
  end

  def keep_home_page_fresh
    # expire home page fragment caches after specified internal to keep it fresh
    if $CACHE_CLEARED_LAST.advance(:hours => $CACHE_CLEAR_IN_HOURS) < Time.now
      expire_cache('home')
      $CACHE_CLEARED_LAST = Time.now()
    end
  end

  # expire a single non-species page fragment cache
  def expire_cache(page_name)
    expire_pages(ContentPage.find_all_by_page_name(page_name))
  end

  # just clear all fragment caches quickly
  def clear_all_caches
    $CACHE.clear
    remove_cached_feeds
    remove_cached_list_of_taxon_concepts
    if ActionController::Base.cache_store.class == ActiveSupport::Cache::MemCacheStore
      ActionController::Base.cache_store.clear
      return true
    else
      return false
    end
  end

  def expire_non_species_caches
    expire_menu_caches
    expire_pages(ContentPage.find_all_by_active(true))
    $CACHE_CLEARED_LAST = Time.now()
  end

  # expire a list of taxa_ids specifed as an array, usually including its ancestors (optionally not)
  # NOTE - this is VERY slow because each taxon is expired individually.  But this is a limitation of memcached.  Unless we
  # want to keep an index of all of the memcached keys related to a given taxon, which itself would be confusing, this is not
  # really possible.
  def expire_taxa(taxa_ids)
    return if taxa_ids.nil?
    raise "Must be called with an array" unless taxa_ids.class == Array
    taxa_ids_to_expire = find_ancestor_ids(taxa_ids)
    return if taxa_ids_to_expire.nil? # Yes, again.  Sorry.
    if taxa_ids_to_expire.length > $MAX_TAXA_TO_EXPIRE_BEFORE_EXPIRING_ALL
      Rails.cache.clear
    else
      expire_taxa_ids_with_error_handling(taxa_ids_to_expire)
    end
  end

  # NOTE: If you want to expire it's ancestors, too, use #expire_taxa.
  def expire_taxon_concept(taxon_concept_id, params = {})
    # TODO: re-implement caching and review caching practices
  end

  # check if the requesting IP address is allowed (used to resrict methods to specific IPs, such as MBL/EOL IPs)
  def allowed_request
    !((request.remote_ip =~ /127\.0\.0\.1/).nil? && (request.remote_ip =~ /128\.128\./).nil? && (request.remote_ip =~ /10\.19\./).nil?)
  end


  # send user back to the non-SSL version of the page
  def redirect_back_to_http
    redirect_to :protocol => "http://", :status => :moved_permanently  if request.ssl?
  end

  # Language Object for the current request.  Stored as an instance variable to speed things up for multiple calls.
  def current_language
    @current_language ||= Language.find(session[:language_id]) rescue Language.default
  end

  def update_current_language(new_language)
    @current_language = new_language
    session[:language_id] = new_language.id
    I18n.locale = new_language.iso_639_1
  end

  # Deceptively simple... but note that memcached will only be hit ONCE per request because of the ||=
  def current_user
    @current_user ||= if session[:user_id]               # Try loading from session
                        User.cached(session[:user_id])   #   Will be nil if there was a problem...
                      elsif cookies[:user_auth_token]    # Try loading from cookie
                        load_user_from_cookie            #   Again, nil if there was a problem...
                      end
    # If the user didn't have a session, didn't have a cookie, OR if there was a problem, they are anonymous:
    @current_user ||= EOL::AnonymousUser.new(current_language)
  end

  def recently_visited_collections(collection_id = nil)
    session[:recently_visited_collections] ||= []
    session[:recently_visited_collections].unshift(collection_id)
    session[:recently_visited_collections] = session[:recently_visited_collections].uniq  # Ignore duplicates.
    session[:recently_visited_collections] = session[:recently_visited_collections][0..5] # Only keep six.
  end

  # Boot all users out when we don't want logins (note: preserves language):
  def clear_any_logged_in_session
    session[:user_id] = nil
  end

  def logged_in?
    session[:user_id]
  end

  def check_authentication
    must_log_in unless logged_in?
    return false
  end

  # used as a before_filter on methods that you don't want users to see if they are logged in
  # such as the sessions#new, users#new, users#forgot_password etc
  def redirect_if_already_logged_in
    if logged_in?
      flash[:notice] = I18n.t(:destination_inappropriate_for_logged_in_users)
      redirect_to(current_user)
    end
  end

  def must_log_in
    respond_to do |format|
      format.html { store_location; redirect_to login_url }
      format.js   { render :partial => 'content/must_login', :layout => false }
    end
    return false
  end

  # call this method if someone is not supposed to get a controller or action when user accounts are disabled
  def accounts_not_available
    flash[:warning] =  I18n.t(:user_system_down)
    redirect_to root_url
  end

  def restrict_to_admins
    raise EOL::Exceptions::SecurityViolation unless current_user.is_admin?
  end

  def restrict_to_curators
    raise EOL::Exceptions::SecurityViolation unless current_user.min_curator_level?(:full)
  end

  # A user is not authorized for the particular controller/action:
  def access_denied(exception = nil)
    flash[:error] << exception.flash_error if exception.respond_to?(:flash_error)
    flash[:error] ||= I18n.t('exceptions.security_violations.default')
    # Beware of redirect loops! Check we are not redirecting back to current URL that user can't access
    store_location(nil) if return_to_url && return_to_url.include?(current_url)
    store_location(referred_url) if referred_url && !return_to_url && !referred_url.include?(current_url)
    redirect_back_or_default
  end

  def not_yet_implemented
    flash[:warning] =  I18n.t(:not_yet_implemented_error)
    redirect_to request.referer ? :back : :default
  end

  def set_language
    language = Language.from_iso(params[:language]) rescue Language.default
    update_current_language(language)
    if logged_in?
      # Don't want to worry about validations on the user; language is simple.  Just update it:
      current_user.update_attribute(:language_id, language.id)
      current_user.clear_cache
    end
    redirect_to(params[:return_to].blank? ? root_url : params[:return_to])
  end

  # pulled over from Rails core helper file so it can be used in controllers as well
  def escape_javascript(javascript)
     (javascript || '').gsub('\\', '\0\0').gsub('</', '<\/').gsub(/\r\n|\n|\r/, "\\n").gsub(/["']/) { |m| "\\#{m}" }
  end

  # logged in users will be redirected to terms agreement if they have not yet accepted.
  def check_user_agreed_with_terms
    if logged_in? && ! current_user.agreed_with_terms
      store_location
      redirect_to terms_agreement_user_path(current_user)
    end
  end

  # Ensure that the user has this in their watch_colleciton, so they will get replies in their newsfeed:
  def auto_collect(what, options = {})
    options[:annotation] ||= I18n.t(:user_left_comment_on_date, :username => current_user.full_name,
                                    :date => I18n.l(Time.now, :format => :long))
    watchlist = current_user.watch_collection
    collection_item = CollectionItem.find_by_collection_id_and_object_id_and_object_type(watchlist.id, what.id,
                                                                                         what.class.name)
    if collection_item.nil?
      collection_item = begin # No care if this fails.
        CollectionItem.create(:annotation => options[:annotation], :object => what, :collection_id => watchlist.id)
      rescue => e
        logger.error "** ERROR COLLECTING: #{e.message} FROM #{e.backtrace.first}"
        nil
      end
      if collection_item && collection_item.save
        return unless what.respond_to?(:summary_name) # Failsafe.  Most things should.
        flash[:notice] ||= ''
        flash[:notice] += ' '
        flash[:notice] += I18n.t(:item_added_to_watch_collection_notice,
                                 :collection_name => self.class.helpers.link_to(watchlist.name,
                                                                                collection_path(watchlist)),
                                 :item_name => what.summary_name)
        CollectionActivityLog.create(:collection => watchlist, :user => current_user,
                             :activity => Activity.collect, :collection_item => collection_item)
      end
    end
  end

  def convert_flash_messages_for_ajax
    [:notice, :error].each do |type|
      if flash[type]
        temp = flash[type]
        flash[type] = ''
        flash.now[type] = temp
      end
    end
  end

  # clear the cached activity logs on homepage
  def clear_cached_homepage_activity_logs
    $CACHE.delete('homepage/activity_logs_expiration') if $CACHE
  end

protected

  # Overrides ActionController::Rescue local_request? to allow custom configuration of which IP addresses
  # are considered to be local requests (versus public) and therefore get full error messages. Modify
  # $LOCAL_REQUEST_ADDRESSES values to toggle between public and local error views when using a local IP.
  def local_request?
    return false unless $LOCAL_REQUEST_ADDRESSES.is_a? Array
    $LOCAL_REQUEST_ADDRESSES.any?{ |local_ip| request.remote_addr == local_ip && request.remote_ip == local_ip }
  end

  # Overrides ActionController::Rescue rescue_action_in_public to render custom views instead of static HTML pages
  # public/404.html and public/500.html. Static pages are still used if exception prevents reaching controller
  # e.g. see ActionController::Failsafe which catches e.g. MySQL exceptions such as database unknown
  def rescue_action_in_public(exception)

    # exceptions in views are wrapped by ActionView::TemplateError and will return 500 response
    # if we use the original_exception we may get a more meaningful response code e.g. 404 for ActiveRecord::RecordNotFound
    if exception.is_a?(ActionView::TemplateError) && defined?(exception.original_exception)
      response_code = response_code_for_rescue(exception.original_exception)
    else
      response_code = response_code_for_rescue(exception)
    end
    render_exception_response(exception, response_code)

    # Log to database
    if $ERROR_LOGGING && !$IGNORED_EXCEPTIONS.include?(exception.to_s)
      ErrorLog.create(
        :url => request.url,
        :ip_address => request.remote_ip,
        :user_agent => request.user_agent,
        :user_id => logged_in? ? current_user.id : 0,
        :exception_name => exception.to_s,
        :backtrace => "Application Server: " + $IP_ADDRESS_OF_SERVER + "\r\n" + exception.backtrace.to_s
      )
    end
    # Notify New Relic about exception
    NewRelic::Agent.notice_error(exception) if $PRODUCTION_MODE
  end

  # custom method to render an appropriate response to an exception
  def render_exception_response(exception, response_code)
    case response_code
    when :unauthorized
      logged_in? ? access_denied : must_be_logged_in
    when :forbidden
      access_denied(exception)
    when :not_implemented
      not_yet_implemented
    else
      status = interpret_status(response_code) # defaults to "500 Unknown Status" if response_code is not recognized
      status_code = status[0,3]
      respond_to do |format|
        format.html do
          @error_page_title = I18n.t("error_#{status_code}_page_title", :default => [:error_default_page_title, "Error."])
          @status_code = status_code
          render :layout => 'v2/errors', :template => 'content/error', :status => status_code
        end
        format.js do
          render :layout => false, :template => 'content/error', :status => status_code
        end
        format.all { render :text => status, :status => status_code }
      end
    end
  end

  # Defines the scope of the controller and action method (i.e. view path) for using in i18n calls
  # Used by meta tag helper methods
  def controller_action_scope
    @controller_action_scope ||= controller_path.split("/") << action_name
  end
  helper_method :controller_action_scope

  # Defines base variables for use in scoped i18n calls, used by meta tag helper methods
  def scoped_variables_for_translations
    @scoped_variables_for_translations ||= {
      :default => '',
      :scope => controller_action_scope }.freeze # frozen to force use of dup, otherwise wrong vars get sent to i18n
  end

  def meta_data(title = meta_title, description = meta_description, keywords = meta_keywords)
    @meta_data ||=  { :title => [
                      @home_page ? I18n.t(:meta_title_site_name) : title.presence,
                      @rel_canonical_href_page_number ? I18n.t(:pagination_page_number, :number => @rel_canonical_href_page_number) : nil,
                      @home_page ? title.presence : I18n.t(:meta_title_site_name)
                    ].compact.join(" - ").strip,
                  :description => description,
                  :keywords => keywords
                }.delete_if{ |k, v| v.nil? }
  end
  helper_method :meta_data

  def meta_title
    return @meta_title unless @meta_title.blank?
    translation_vars = scoped_variables_for_translations.dup
    translation_vars[:default] = @page_title if !@page_title.nil? && translation_vars[:default].blank?
    @meta_title = t(".meta_title", translation_vars)
  end

  def meta_description
    @meta_description ||= t(".meta_description", scoped_variables_for_translations.dup)
  end

  def meta_keywords
    @meta_keywords ||= t(".meta_keywords", scoped_variables_for_translations.dup)
  end

  def tweet_data(text = nil, hashtags = nil, lang = I18n.locale.to_s, via = $TWITTER_USERNAME)
    return @tweet_data unless @tweet_data.blank?
    if text.nil?
      translation_vars = scoped_variables_for_translations.dup
      translation_vars[:default] = meta_title if translation_vars[:default].blank?
      text = I18n.t(:tweet_text, translation_vars)
    end
    @tweet_data = {:lang => lang, :via => via, :hashtags => hashtags,
                   :text => text}.delete_if{ |k, v| v.blank? }
  end
  helper_method :tweet_data

  def meta_open_graph_data
    @meta_open_graph_data ||= {
      'og:url' => meta_open_graph_url,
      'og:site_name' => I18n.t(:encyclopedia_of_life),
      'og:type' => 'website', # TODO: we may want to extend to other types depending on the page see http://ogp.me/#types
      'og:title' => meta_data[:title],
      'og:description' => meta_data[:description],
      'og:image' => meta_open_graph_image_url || view_helper_methods.image_url('v2/logo_open_graph_default.png')
    }.delete_if{ |k, v| v.blank? }
  end
  helper_method :meta_open_graph_data

  def meta_open_graph_url
    @meta_open_graph_url ||= request.url
  end

  def meta_open_graph_image_url
    @meta_open_graph_image_url ||= nil
  end

  # rel canonical only cares about page param for paginated records with current_page greater than 1
  def rel_canonical_href_page_number(records)
    @rel_canonical_href_page_number ||= records.is_a?(WillPaginate::Collection) && records.current_page > 1 ?
      records.current_page : nil
  end

  # rel prev href needs the current request params with current page number swapped out for the number of the previous page
  # return nil if there is no previous page
  def rel_prev_href_params(records, original_params = original_request_params.clone)
    @rel_prev_href_params ||= records.is_a?(WillPaginate::Collection) && records.previous_page ?
      original_params.merge({ :page => records.previous_page }) : nil
  end

  # rel next href needs the current request params with current page number swapped out for the number of the next page
  # return nil if there is no next page
  def rel_next_href_params(records, original_params = original_request_params.clone)
    @rel_next_href_params ||= records.is_a?(WillPaginate::Collection) && records.next_page ?
      original_params.merge({ :page => records.next_page }) : nil
  end

  # Set in before filter and frozen so we have an unmodified copy of request params for use in rel link tags
  def original_request_params
    return @original_request_params if @original_request_params
    if params[:controller] == 'search' && params[:action] == 'index' && params[:id]
      if params[:q].blank?
        params["q"] = params["id"]
      end
      params.delete("id")
    end
    @original_request_params ||= params.clone.freeze # frozen because we don't want @original_request_params to be modified
  end

  def page_title
    @page_title ||= t(".page_title", :scope => controller_action_scope)
  end
  helper_method :page_title

  # NOTE - these two are TOTALLY DUPLICATED from application_helper, because I CAN'T GET COLLECTIONS TO WORK.  WTF?!?
  def link_to_item(item, options = {})
    case item.class.name
    when 'Collection'
      collection_url(item, options)
    when 'Community'
      community_url(item, options)
    when 'DataObject'
      data_object_url(item, options)
    when 'User'
      user_url(item, options)
    when 'TaxonConcept'
      taxon_url(item, options)
    else
      raise EOL::Exceptions::ObjectNotFound
    end
  end
  def link_to_newsfeed(item, options = {})
    case item.class.name
    when 'Collection'
      collection_newsfeed_url(item, options)
    when 'Community'
      community_newsfeed_url(item, options)
    when 'DataObject'
      data_object_url(item, options)
    when 'User'
      user_newsfeed_url(item, options)
    when 'TaxonConcept'
      taxon_url(item, options)
    else
      raise EOL::Exceptions::ObjectNotFound
    end
  end
private

  def find_ancestor_ids(taxa_ids)
    taxa_ids = taxa_ids.map do |taxon_concept_id|
      taxon_concept = TaxonConcept.find_by_id(taxon_concept_id)
      taxon_concept.nil? ? nil : taxon_concept.ancestry.collect {|an| an.taxon_concept_id}
    end
    taxa_ids.flatten.compact.uniq
  end

  def expire_taxa_ids_with_error_handling(taxa_ids_to_expire)
    messages = []
    taxa_ids_to_expire.each do |id|
      begin
        expire_taxon_concept(id)
      rescue => e
        messages << "Unable to expire TaxonConcept #{id}: #{e.message}"
      end
    end
    raise messages.join('; ') unless messages.empty?
  end

  def remove_cached_feeds
    FileUtils.rm_rf(Dir.glob("#{RAILS_ROOT}/public/feeds/*"))
  end

  def remove_cached_list_of_taxon_concepts
    FileUtils.rm_rf("#{RAILS_ROOT}/public/content/tc_api/page")
    expire_page( :controller => 'content', :action => 'tc_api' )
  end

  # Having a *temporary* logged in user, as opposed to reading the user from the cache, lets us change some values
  # (such as language or vetting) within the scope of a request *without* storing it the database.  So, for example,
  # when a URL includes "&vetted = true" (or some-such), we can serve that request with *temporary* user values that
  # don't change the user's DB values.
  def temporary_logged_in_user
    @logged_in_user
  end

  def set_temporary_logged_in_user(user)
    @logged_in_user = user
  end

  def expire_pages(pages)
    if pages.length > 0
      Language.find_active.each do |language|
        pages.each do |page|
          if page.class == ContentPage
            expire_fragment(:controller => '/content', :part => "#{page.id.to_s }_#{language.iso_639_1}")
            expire_fragment(:controller => '/content',
                            :part => "#{page.page_url.underscore_non_word_chars.downcase}_#{language.iso_639_1}")
            page.clear_all_caches rescue nil # TODO - still having some problem with ContentPage, not sure why.
          else
            expire_fragment(:controller => '/content', :part => "#{page}_#{language.iso_639_1}")
          end
          if page.class == ContentPage && page.page_url == 'home'
            Hierarchy.all.each do |h|
              expire_fragment(:controller => '/content', :part => "home_#{language.iso_639_1}_#{h.id.to_s}") # this is because the home page fragment is dependent on the user's selected hierarchy entry ID, unlike the other content pages
            end
          end
        end
      end
    end
  end

  def log_search params
    Search.log(params, request, current_user) if EOL.allowed_user_agent?(request.user_agent)
  end

  def update_logged_search params
    Search.update_log(params)
  end

  # Before filter
  def check_if_mobile
    # To-do if elsif elsif elsif.. This works but it's not really elegant!
    if mobile_agent_request? && !mobile_url_request? && !mobile_disabled_by_session?
      if params[:controller] == "taxa/overviews" && params[:taxon_id]
        redirect_to mobile_taxon_path(params[:taxon_id]), :status => :moved_permanently
      elsif params[:controller] == "taxa/details" && params[:taxon_id]
        redirect_to mobile_taxon_details_path(params[:taxon_id]), :status => :moved_permanently
      elsif params[:controller] == "taxa/media" && params[:taxon_id]
        redirect_to mobile_taxon_media_path(params[:taxon_id]), :status => :moved_permanently
      else
        redirect_to mobile_contents_path, :status => :moved_permanently
      end
    end
  end

  def mobile_agent_request?
    request.env["HTTP_USER_AGENT"] && request.env["HTTP_USER_AGENT"][/(iPhone|iPod|iPad|Android|IEMobile)/]
  end
  helper_method :mobile_agent_request?

  def mobile_url_request?
    request.request_uri.to_s.include? "\/mobile\/"
  end
  helper_method :mobile_url_request?

  def mobile_disabled_by_session?
    session[:mobile_disabled] && session[:mobile_disabled] == true
  end
  helper_method :mobile_disabled_by_session?

  def load_user_from_cookie
    begin
      user = User.find_by_remember_token(cookies[:user_auth_token]) rescue nil
      session[:user_id] = user.id # The cookie will persist, but now we can log in directly from the session.
      user
    rescue ActionController::SessionRestoreError => e
      reset_session
      cookies.delete(:user_auth_token)
      logger.warn "!! Rescued a corrupt cookie."
      nil
    end
  end

end
