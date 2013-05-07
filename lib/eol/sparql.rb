module EOL
  module Sparql

    BASIC_URI_REGEX = /^http:\/\/[^ ]+$/i
    ENCLOSED_URI_REGEX = /^<http:\/\/[^ ]+>$/i
    NAMESPACED_URI_REGEX = /^([a-z0-9_-]{1,30}):(.*)$/i
    # TODO - it would be handy if this read from a config file (or at least added things from a config file):
    NAMESPACES = {
        'dwc' => 'http://rs.tdwg.org/dwc/terms/',
        'dwct' => 'http://rs.tdwg.org/dwc/dwctype/',
        'dc' => 'http://purl.org/dc/terms/',
        'rdf' => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
        'rdfs' => 'http://www.w3.org/2000/01/rdf-schema#',
        'foaf' => 'http://xmlns.com/foaf/0.1/',
        'eol' => 'http://eol.org/schema/terms/',
        'obis' => 'http://iobis.org/schema/terms/',
        'owl' => 'http://www.w3.org/2002/07/owl#',
        'anage' => 'http://anage.org/schema/terms/'
      }

    def self.connection
      EOL::Sparql::VirtuosoClient.new(
        :endpoint_uri => $VIRTUOSO_SPARQL_ENDPOINT_URI,
        :upload_uri => $VIRTUOSO_UPLOAD_URI,
        :username => $VIRTUOSO_USER,
        :password => $VIRTUOSO_PW)
    end

    def self.to_underscore(str)
      convert(str.downcase.tr(' ','_'))
    end

    def self.uri_to_readable_label(uri)
      if matches = uri.to_s.match(/(\/|#)([a-z0-9_-]{3,})$/i)
        return matches[2].underscore.tr('_', ' ').capitalize_all_words
      end
    end

    def self.uri_in_eol_triplestore(uri)
      uri.to_s =~ /^http:\/\/(eol.org\/resources\/[0-9]+\/(taxa|occurrences|events)\/|anage\.org|adw\.org|iobis\.org|reeffish\.org)/
    end

    def self.get_unit_components_from_metadata(metadata)
      if hash = metadata.detect{ |k,v| k == 'http://rs.tdwg.org/dwc/terms/measurementUnit' }
        return components_of_unit_of_measure_label_for_uri(hash[1])
      end
    end

    def self.components_of_unit_of_measure_label_for_uri(uri)
      if measurement_uri = implied_unit_of_measure_for_uri(uri)
        uri = measurement_uri
      end
      if lookup_uri = is_known_unit_of_measure_uri(uri)
        return uri_components(lookup_uri)
      end
    end

    def self.implied_unit_of_measure_for_uri(uri)
      return uri.has_unit_of_measure if uri.is_a?(KnownUri) && !uri.is_unit_of_measure?
      if known_uri = KnownUri.find_by_uri(uri.to_s)
        return known_uri.has_unit_of_measure
      end
    end

    def self.is_known_unit_of_measure_uri(uri)
      return uri if uri.is_a?(KnownUri) && uri.is_unit_of_measure?
      known_uri = KnownUri.find_by_uri(uri.to_s)
      if known_uri && known_uri.is_unit_of_measure?
        return known_uri
      end
    end

    def self.uri_components(uri)
      if uri.is_a?(KnownUri)
        return { uri: uri.uri, label: uri.name }
      elsif label = EOL::Sparql.uri_to_readable_label(uri)
        return { uri: uri, label: label }
      else
        return { uri: uri, label: uri }
      end
    end

    def self.is_uri?(string)
      return true if string =~ BASIC_URI_REGEX
      return true if string =~ ENCLOSED_URI_REGEX
      return true if string =~ NAMESPACED_URI_REGEX
      false
    end

    def self.enclose_value(value)
      return "<" + value + ">" if value =~ BASIC_URI_REGEX
      "\"" + value + "\""
    end

    # Puts URIs in <brackets>, dereferences namespaces, and quotes literals.
    def self.expand_namespaces(input)
      value = input.to_s
      if value =~ BASIC_URI_REGEX                              # full URI
        return value
      elsif value =~ ENCLOSED_URI_REGEX                        # full URI
        return value
      elsif matches = value.match(NAMESPACED_URI_REGEX)        # namespace
        if full_uri = EOL::Sparql::NAMESPACES[matches[1]]
          return full_uri + matches[2]
        else
          return false  # this is the failure - an unknown namespace was given
        end
      end
      return value                                             # literal value
    end

    def self.convert(str)
       str.gsub!("&", "&amp;")
       str.gsub!("<", "&lt;")
       str.gsub!(">", "&gt;")
       str.gsub!("'", "&apos;")
       str.gsub!("\"", "&quot;")
       str.gsub!("\\", "")
       str.gsub!("\n", "")
       str.gsub!("\r", "")
       str
    end

  end
end
