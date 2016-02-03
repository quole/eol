class TraitBank
  # NOTE: You CANNOT call this "Search," you will get an error. I think we've
  # used that name elsewhere and it conflicts. A Rails 3 problem, that, but I
  # don't care enough to find and fix it.
  class Scan
    class << self
      # LATER:
      # - querystrings
      # - min / max values
      # - units
      # - equivalent values
      # - pagination
      #
      # { querystring: @querystring, attribute: @attribute,
      #   min_value: @min_value, max_value: @max_value,
      #   unit: @unit, sort: @sort, language: current_language,
      #   taxon_concept: @taxon_concept,
      #   required_equivalent_attributes: @required_equivalent_attributes,
      #   required_equivalent_values: @required_equivalent_values }
      def for(search)
        if search[:taxon_concept]
          if search[:querystring]
            raise "Not yet"
          else
            data_search_within_clade(search[:attribute],
              search[:taxon_concept].id)
          end
        else
          if search[:querystring]
            raise "Not yet"
          else
            data_search_predicate(search[:attribute])
          end
        end
      end

      # NOTE: PREFIX eol: <http://eol.org/schema/>
      # PREFIX dwc: <http://rs.tdwg.org/dwc/terms/>
      # e.g.: http://purl.obolibrary.org/obo/OBA_0000056
      def scan_query(options = {})
        limit = options[:limit] || 100
        offset = options[:offset]
        clade = options[:clade]
        query = "# data_search part 1\n"
        fields = "DISTINCT ?page ?trait"
        fields = "COUNT(*)" if options[:count]
        query += "SELECT #{fields} WHERE { "\
          "GRAPH <http://eol.org/traitbank> { "\
          "?page a eol:page . "\
          "?page <#{options[:attribute]}> ?trait . "
        if clade
          query += "?page eol:has_ancestor <http://eol.org/pages/#{clade}> . "
        end
        # TODO: This ORDER BY only really works if numeric! :S
        query += "?trait a eol:trait . "\
          "?trait dwc:measurementValue ?value . } } "
        unless options[:count]
          # TODO: figure out how to sort properly, both numerically and alpha.
          orders = ["xsd:float(REPLACE(?value, \",\", \"\"))"] #, "?value"]
          orders.map! { |ord| "DESC(#{ord})" } if options[:sort] =~ /^desc$/i
          query += "ORDER BY #{orders.join(" ")} "
          query += "LIMIT #{limit} "\
          "#{"OFFSET #{offset}" if offset}"
        end
        query
      end

      # NOTE: I copy/pasted this. TODO: generalize. For testing, 37 should include
      # 41, and NOT include 904.
      def data_search_within_clade(predicate, clade, limit = 100, offset = nil)
        query = "SELECT DISTINCT *
        # data_search_within_clade
        WHERE {
          GRAPH <http://eol.org/traitbank> {
            ?page <#{predicate}> ?trait .
            ?page eol:has_ancestor <http://eol.org/pages/#{clade}> .
            ?trait a eol:trait .
            ?trait ?trait_predicate ?value .
            OPTIONAL { ?value a eol:trait . ?value ?meta_predicate ?meta_value }
          }
        }
        LIMIT #{limit}
        #{"OFFSET #{offset}" if offset}"
        TraitBank.connection.query(query)
      end
    end
  end
end