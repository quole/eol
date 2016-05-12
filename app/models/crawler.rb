# A class to crawl over all the taxon pages and refresh them in various ways.
class Crawler
  @queue = "crawler"

  def self.enqueue
    offset = 0
    limit = 10_000
    filename = Rails.root.join("public", "traitbank-#{Date.today}.json").to_s
    File.unlink(filename) if File.exist?(filename)
    File.open(filename, "a") { |f| f.puts(data_feed_opening) }
    ids = [] # Probably superfluous, but want to be safe because of #while
    begin
      ids = TaxonConcept.published.limit(limit).order(:id).offset(offset).pluck(:id)
      Resque.enqueue(Crawler, from: ids.first, to: ids.last, filename: filename)
      offset += limit
    end while ids.size > 0
    Resque.enqueue(Crawler, close: true, filename: filename)
  end

  def self.perform(options)
    if options[:close]
      File.open(options[:filename], "a") { |f| f.puts(data_feed_closing) }
      return EOL.log("Crawler COMPLETE! Closed file.", prefix: "C")
    end
    unless options[:from] && options[:to]
      return EOL.log("Crawler: FAILED... from/to missing: #{options.inspect}",
        prefix: "!")
    end
    EOL.log("Crawler: (#{options[:from]}-#{options[:to]})", prefix: "C")
    EOL.log("NO FILENAME! Only building the caches...") unless
      options.has_key?(:filename)
    taxa = TaxonConcept.published.
                 where(["id >= ? AND id <= ?", options[:from], options[:to]])
    count = taxa.count
    taxa.each_with_index do |concept, index|
      begin
        pj = PageJson.for(concept.id)
        EOL.log("#{index}/#{count}: #{concept.id} (#{pj.ld.to_s.size})",
          prefix: ".") if index % 10 == 0
        if options[:filename]
          File.open(options[:filename], "a") do |f|
            JSON.pretty_generate(pj.ld).gsub(/^/m, "      ")
          end
        end
      rescue => e
        EOL.log("ERROR on page #{concept.id}:", prefix: "!")
        EOL.log_error(e)
      end
      sleep(1) # Minimize load on production.
    end
  end

  def self.data_feed_opening
    context = {}
    KnownUri.show_in_gui.each do |uri|
      context[uri.name] = uri.uri
    end
    more = {}
    TraitBank::JsonLd.add_default_context(more)
    context.merge!(more["@context"])
    %Q%
    {
      "@context": #{JSON.pretty_generate(context).gsub(/^/m, "      ")},
      "@type": "DataFeed",
      "name": "Company directory",
      "dateModified": "#{Date.today}",
      "dataFeedElement": [
    %
  end

  def self.data_feed_closing
    %Q%
      ]
    }
    %
  end
end
