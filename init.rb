require 'redmine'

Redmine::Plugin.register :redmine_csv_file_importer do
  name 'CSV File Importer'
  author 'Dany Poupard'
  description 'CSV file import plugin for Redmine.'
  version '1.1.0'

  requires_redmine :version_or_higher => '0.9.0'
  
  project_module :csv_file_importer do
    permission :import, :csv_file_importer => :index
  end
  
  menu :project_menu, :csv_file_importer, { :controller => 'csv_file_importer', :action => 'index' }, 
	:caption => :label_csv_file_importer, :before => :settings, :param => :project_id

  settings :partial => 'settings/csv_file_importer_settings',
    :default => {
      'csv_import_issue_id' => ''
    }
end
