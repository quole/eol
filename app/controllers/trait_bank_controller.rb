class TraitBankController < ApplicationController
  layout "taxa"

  def show
    @taxon_concept = TaxonConcept.find(params[:id])
    @taxon_page = TaxonPage.new(@taxon_concept, current_user)
    @scientific_name = @taxon_page.title
    # Use TC id here, not param, incase it was superceded!
    @page_traits = PageTraits.new(@taxon_concept.id)
    @jsonld = @page_traits.jsonld
  end
end
