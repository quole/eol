$(function(){$(".rating ul a").on("click",function(){var e=$(this),t=e.closest("ul").find("a").index(e);return t++,e.closest("ul").find("li[class^=current]").removeClass().addClass("current_rating_"+t).text("Current rating: "+t+" of 5"),e.closest(".ratings").addClass("rated"),!1})});