Rails.cache ||= Rails.cache

class String

  # Normalize a string for better matching, e.g. for searches
  def normalize
    # Remember, inline regexes can leak memory.  Storing as variables avoids this.
    @@normalization_regex ||= /[;:,\.\(\)\[\]\!\?\*_\\\/\"\']/
    @@spaces_regex        ||= /\s+/
    @@tag_regex           ||= /<[^>]*>/
    name = self.clone
    return name.downcase.gsub(@@normalization_regex, '').gsub(@@tag_regex, '').gsub(@@spaces_regex, ' ')
    return name.downcase.gsub(@@normalization_regex, '').gsub(@@spaces_regex, ' ')
  end

  # Few languages can "safely" downcase. For example, in German, it's quite awkward to downcase nouns. So:
  def downcase_with_language_exceptions
    return self unless I18n && I18n.locale && [:en, :es, :fr].include?(I18n.locale)
    return self.downcase_without_language_exceptions
  end
  alias_method_chain :downcase, :language_exceptions

  def strip_italics
    self.gsub(/<\/?i>/i, "")
  end

  def underscore_non_word_chars
    @@non_word_chars_regex ||= /[^A-Za-z0-9\/]/
    @@dup_underscores_regex ||= /__+/
    string = self.clone
    string.gsub(@@non_word_chars_regex, '_').gsub(@@dup_underscores_regex, '_')
  end
  
  def capitalize_all_words_if_using_english
    if I18n.locale == 'en' || I18n.locale == :en
      # This is only safe in English:
      capitalize_all_words
    else
      self
    end
  end
  
  def capitalize_all_words
    string = self.clone
    unless string.blank?
      string = string.split(/ /).map {|w| w.firstcap }.join(' ')
    end
    string
  end
  
end

module ActiveRecord
  class Base
    class << self

      # options is there so that we can pass in the :serialize => true option in the cases where we were using Yaml...
      # I am going to try NOT doing anything with that option right now, to see if it works.  If not, however, I want
      # to at least have it passed in when we needed it, so the code can change later if needed.
      def cached_find(field, value, options = {})
        key = "#{field}/#{value}"
        r = cached(key, options) do
          r = send("find_by_#{field}", value, :include => options[:include])
        end
        r
      end

      def cached_read(key)
        name = cached_name_for(key)
        # TODO: to avoid the => undefined class/module Agent - type of errors when reading
        # cached instances with associations preloaded. Very hacky, I apologize
        if !Rails.configuration.cache_classes && defined?(self::CACHE_ALL_ROWS_DEFAULT_INCLUDES)
          if self.name == 'Hierarchy'
            Agent
            Resource
            ContentPartner
            User
          elsif self.name == 'TocItem'
            InfoItem
          elsif self.name == 'InfoItem'
            TocItem
          end
        end
        Rails.cache.read(name)
      end

      def cached(key, options = {}, &block)
        name = cached_name_for(key)
        if Rails.cache # Sometimes during tests, cache has not yet been initialized.
          if v = Rails.cache.read(name)
            return v
          else
            Rails.cache.delete(name) if Rails.cache.exist?(name)
            Rails.cache.fetch(name) do
              yield
            end
          end
        else
          yield
        end
      end

      def cached_name_for(key)
        "#{Rails.env}/#{self.table_name}/#{key.underscore_non_word_chars}"[0..249]
      end
    end
  end
end

if $ENABLE_TRANSLATION_LOGS
  module I18n
    def self.translate_with_logging(*args)
      Logging::TranslationLog.inc(args[0])
      I18n.translate_without_logging(*args)
    end
    class << self
      alias_method_chain :translate, :logging
      alias :t :translate
    end
  end
end
