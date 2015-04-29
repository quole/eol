# No, I am not putting this in lib. ...These are TOTALLY dependent on EOL and
# would make no sense in any other universe. It's a model for our use.
class SparqlQuery
  TAXON_PREFIX = Rails.configuration.uri_prefix_taxon

  GGI_URIS = [
    'http://eol.org/schema/terms/NumberRichSpeciesPagesInEOL',
    'http://eol.org/schema/terms/NumberOfSequencesInGenBank',
    'http://eol.org/schema/terms/NumberRecordsInGBIF',
    'http://eol.org/schema/terms/NumberRecordsInBOLD',
    'http://eol.org/schema/terms/NumberPublicRecordsInBOLD',
    'http://eol.org/schema/terms/NumberSpecimensInGGBN',
    'http://eol.org/schema/terms/NumberReferencesInBHL'
  ]

  class << self # Everything is a class method.
    def measurements(taxon_concept)
      EOL::Sparql.connection.query(
        "SELECT DISTINCT ?attribute ?value ?unit_of_measure_uri
          ?statistical_method ?life_stage ?sex ?data_point_uri ?graph
          ?taxon_concept_id
        WHERE {
          GRAPH ?graph {
            ?data_point_uri dwc:measurementType ?attribute .
            ?data_point_uri dwc:measurementValue ?value .
            OPTIONAL { ?data_point_uri dwc:measurementUnit ?unit_of_measure_uri } .
            OPTIONAL { ?data_point_uri eolterms:statisticalMethod ?statistical_method } .
          } .
          {
            ?data_point_uri dwc:taxonConceptID ?taxon_concept_id .
            FILTER( ?taxon_concept_id = <#{SparqlQuery::TAXON_PREFIX}#{taxon_concept.id}>)
            OPTIONAL { ?data_point_uri dwc:lifeStage ?life_stage } .
            OPTIONAL { ?data_point_uri dwc:sex ?sex }
          }
          UNION {
            ?data_point_uri dwc:occurrenceID ?occurrence .
            ?occurrence dwc:taxonID ?taxon .
            ?data_point_uri eol:measurementOfTaxon eolterms:true .
            GRAPH ?resource_mappings_graph {
              ?taxon dwc:taxonConceptID ?taxon_concept_id .
              FILTER( ?taxon_concept_id = <#{SparqlQuery::TAXON_PREFIX}#{taxon_concept.id}>)
            }
            OPTIONAL { ?occurrence dwc:lifeStage ?life_stage } .
            OPTIONAL { ?occurrence dwc:sex ?sex }
          }
        }
        LIMIT 800"
      )
    end

    def associations(taxon_concept)
      EOL::Sparql.connection.query(
        "SELECT DISTINCT ?attribute ?value ?target_taxon_concept_id
          ?inverse_attribute ?data_point_uri ?graph
        WHERE {
          GRAPH ?resource_mappings_graph {
            ?taxon dwc:taxonConceptID ?source_taxon_concept_id .
            FILTER(?source_taxon_concept_id = <#{SparqlQuery::TAXON_PREFIX}#{taxon_concept.id}>) .
            ?value dwc:taxonConceptID ?target_taxon_concept_id
          } .
          GRAPH ?graph {
            ?occurrence dwc:taxonID ?taxon .
            ?target_occurrence dwc:taxonID ?value .
            {
              ?data_point_uri dwc:occurrenceID ?occurrence .
              ?data_point_uri eol:targetOccurrenceID ?target_occurrence .
              ?data_point_uri eol:associationType ?attribute
            }
            UNION
            {
              ?data_point_uri dwc:occurrenceID ?target_occurrence .
              ?data_point_uri eol:targetOccurrenceID ?occurrence .
              ?data_point_uri eol:associationType ?inverse_attribute
            }
          } .
          OPTIONAL {
            GRAPH ?mappings {
              ?inverse_attribute owl:inverseOf ?attribute
            }
          }
        }
        LIMIT 800"
      )
    end

    def ranges(taxon_concept)
      EOL::Sparql.connection.query(
        "SELECT ?attribute, COUNT(DISTINCT ?descendant_concept_id) as ?count_taxa,
          COUNT(DISTINCT ?data_point_uri) as ?count_measurements,
          MIN(xsd:float(?value)) as ?min, MAX(xsd:float(?value)) as ?max, ?unit_of_measure_uri
        WHERE {
          ?parent_taxon dwc:taxonConceptID <#{SparqlQuery::TAXON_PREFIX}#{taxon_concept.id}> .
          ?t dwc:parentNameUsageID+ ?parent_taxon .
          ?t dwc:taxonConceptID ?descendant_concept_id .
          ?occurrence dwc:taxonID ?taxon .
          ?taxon dwc:taxonConceptID ?descendant_concept_id .
          ?data_point_uri dwc:occurrenceID ?occurrence .
          ?data_point_uri eol:measurementOfTaxon ?measurementOfTaxon .
          ?data_point_uri dwc:measurementType ?attribute .
          ?data_point_uri dwc:measurementValue ?value .
          OPTIONAL {
            ?data_point_uri dwc:measurementUnit ?unit_of_measure_uri
          }
          FILTER (
            ?attribute IN
              (IRI(<#{KnownUri.uris_for_clade_aggregation.join(">),IRI(<")}>))
            && ?measurementOfTaxon = <#{Rails.configuration.uri_true}>
          )
        }
        GROUP BY ?attribute ?unit_of_measure_uri
        ORDER BY DESC(?min)"
      )
    end

    def metadata(uris_to_lookup)
      EOL::Sparql.connection.query(
        "SELECT DISTINCT ?parent_uri ?attribute ?value ?unit_of_measure_uri
        WHERE {
          GRAPH ?graph {
            {
              ?parent_uri ?attribute ?value .
            } UNION {
              ?parent_uri dwc:occurrenceID ?occurrence .
              ?occurrence ?attribute ?value .
            } UNION {
              ?measurement eol:parentMeasurementID ?parent_uri .
              ?measurement dwc:measurementType ?attribute .
              ?measurement dwc:measurementValue ?value .
              OPTIONAL { ?measurement dwc:measurementUnit ?unit_of_measure_uri } .
            } UNION {
              ?parent_uri dwc:occurrenceID ?occurrence .
              ?measurement dwc:occurrenceID ?occurrence .
              ?measurement dwc:measurementType ?attribute .
              ?measurement dwc:measurementValue ?value .
              FILTER NOT EXISTS { ?measurement eol:measurementOfTaxon eolterms:true } .
              OPTIONAL { ?measurement dwc:measurementUnit ?unit_of_measure_uri } .
            } UNION {
              ?measurement eol:associationID ?parent_uri .
              ?measurement dwc:measurementType ?attribute .
              ?measurement dwc:measurementValue ?value .
              OPTIONAL { ?measurement dwc:measurementUnit ?unit_of_measure_uri } .
            } UNION {
              ?parent_uri dwc:occurrenceID ?occurrence .
              ?occurrence dwc:eventID ?event .
              ?event ?attribute ?value .
            } UNION {
              ?parent_uri dwc:occurrenceID ?occurrence .
              ?occurrence dwc:taxonID ?taxon .
              ?taxon ?attribute ?value .
              FILTER (?attribute = dwc:scientificName)
            }
            FILTER (?attribute NOT IN (rdf:type, dwc:taxonConceptID, dwc:measurementType, dwc:measurementValue,
                                       dwc:measurementID, eolreference:referenceID,
                                       eol:targetOccurrenceID, dwc:taxonID, dwc:eventID,
                                       eol:associationType,
                                       dwc:measurementUnit, dwc:occurrenceID, eol:measurementOfTaxon)
                    ) .
            FILTER (?parent_uri IN (<#{uris_to_lookup.join('>,<')}>))
          }
        }"
      )
    end

    def ggi(taxon_concept)
      EOL::Sparql.connection.query(
        "SELECT DISTINCT ?attribute ?value ?data_point_uri ?graph ?taxon_concept_id
        WHERE {
          GRAPH ?graph {
            ?data_point_uri dwc:measurementType ?attribute .
            ?data_point_uri dwc:measurementValue ?value .
            FILTER ( ?attribute IN (<#{GGI_URIS.join(">,<")}>))
          } .
          {
            ?data_point_uri dwc:occurrenceID ?occurrence .
            ?occurrence dwc:taxonID ?taxon .
            ?data_point_uri eol:measurementOfTaxon eolterms:true .
            ?taxon dwc:taxonConceptID ?taxon_concept_id .
            FILTER ( ?taxon_concept_id = <#{SparqlQuery::TAXON_PREFIX}#{taxon_concept.id}>) .
          }
        }
        LIMIT 100"
      )
    end

    def iucn_data_objects(taxon_concept)
      EOL::Sparql.connection.query(
        "SELECT DISTINCT ?attribute ?value ?data_point_uri ?graph ?taxon_concept_id
          WHERE {
            GRAPH ?graph {
              ?data_point_uri dwc:measurementType ?attribute .
              ?data_point_uri dwc:measurementValue ?value.
              FILTER (?attribute = <http://rs.tdwg.org/ontology/voc/SPMInfoItems#ConservationStatus>)
            }.
            {
              ?data_point_uri dwc:occurrenceID ?occurrence .
              ?occurrence dwc:taxonID ?taxon .
              ?taxon dwc:taxonConceptID ?taxon_concept_id .
              FILTER (?taxon_concept_id = <#{SparqlQuery::TAXON_PREFIX}#{taxon_concept.id}>)
            }
          }"
      )
    end
  end
end
