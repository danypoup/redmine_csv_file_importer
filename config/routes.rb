ActionController::Routing::Routes.draw do |map|
#  map.connect 'projects/:id/code_review/:action', :controller => 'csv_file_importer'
  map.connect 'projects/:project_id/csv_file_importer/:action', :controller => 'csv_file_importer'  
end