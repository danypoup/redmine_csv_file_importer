require 'fastercsv'
require 'tempfile'
require 'iconv'

class CsvFileImporterController < ApplicationController
  unloadable
  
  before_filter :find_project

  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
    :author, :description, :category, :priority, :tracker, :status,
    :start_date, :due_date, :done_ratio, :estimated_hours]
  
  CSV_IMPORT_ID = "CSV-IMP-ID"

  def index
  end

  def match
    # Delete existing cfiip to ensure there can't be two cfiips for a user
    CsvFileImportInProgress.delete_all(["user_id = ?",User.current.id])
	
    # save import-in-progress data
    cfiip = CsvFileImportInProgress.find_or_create_by_user_id(User.current.id)
	cfiip.import_type = params[:import_type]
    cfiip.quote_char = params[:wrapper]
    cfiip.col_sep = params[:splitter]
    cfiip.encoding = params[:encoding]
    cfiip.created = Time.new
    cfiip.csv_data = params[:file].read
    cfiip.save
    
    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = cfiip.created.strftime("%Y-%m-%d %H:%M:%S")
    @original_filename = params[:file].original_filename
    
    # display sample
    sample_count = 5
    i = 0
    @samples = []
	
	# Detects real encoding and converts as necessary
	latin = latin_encoding(cfiip.encoding, cfiip.csv_data)
	if latin[:latin]
			cfiip.csv_data = latin[:data]
			cfiip.encoding = latin[:encoding]
	end
	
    FasterCSV.new(cfiip.csv_data, {:headers=>true,
    :encoding=>cfiip.encoding, :quote_char=>cfiip.quote_char, :col_sep=>cfiip.col_sep}).each do |row|
      @samples[i] = row
     
      i += 1
      if i >= sample_count
        break
      end
    end # do
    
    if @samples.size > 0
      @headers = @samples[0].headers
    end
    
	case cfiip.import_type
		when 'issue'
		    # fields
		    @attrs = Array.new
		    ISSUE_ATTRS.each do |attr|
		      #@attrs.push([l_has_string?("field_#{attr}".to_sym) ? l("field_#{attr}".to_sym) : attr.to_s.humanize, attr])
		      @attrs.push([l_or_humanize(attr, :prefix=>"field_"), attr])
		    end
			
		    @project.all_issue_custom_fields.each do |cfield|
		      @attrs.push([cfield.name, cfield.name])
		    end
			
		    @attrs.sort!
			render_template = 'issue'
	
		when 'time_entry'
			render_template = 'time_entry'
    end
	
	render(:template => "csv_file_importer/match_" + render_template)
  end

  def result
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_events = Hash.new
    @affect_projects_issues = Hash.new
    
    # Retrieve saved import data
    cfiip = CsvFileImportInProgress.find_by_user_id(User.current.id)
    if cfiip == nil
      flash[:error] = "No import is currently in progress"
      return
    end

    if cfiip.created.strftime("%Y-%m-%d %H:%M:%S") != params[:import_timestamp]
      flash[:error] = "You seem to have started another import " \
          "since starting this one. " \
          "This import cannot be completed"
      return
    end
    
	# Detects real encoding and converts as necessary
	latin = latin_encoding(cfiip.encoding, cfiip.csv_data)
	if latin[:latin]
			cfiip.csv_data = latin[:data]
			cfiip.encoding = latin[:encoding]
	end
	
	# Import
	case cfiip.import_type
		when 'issue'
			import_issues(cfiip.csv_data, true, cfiip.encoding, cfiip.quote_char, cfiip.col_sep, params)
			render_template = 'issue'
	
		when 'time_entry'
			import_time_entries(cfiip.csv_data, true, cfiip.encoding, cfiip.quote_char, cfiip.col_sep)
			render_template = 'time_entry'
    end
	
    # Clean up after ourselves
    cfiip.delete
    
    # Garbage prevention: clean up cfiips older than 3 days
    CsvFileImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])
	
	render(:template => "csv_file_importer/result_" + render_template)
  end

private

  def find_project
	if params[:project_id] != nil
		project_id = params[:project_id]
		if project_id != -1
			@project = Project.find(project_id)
		end
	end
  end
  
  # Add ISO-8859-1 (or Latin1) and ISO-8859-15 (or Latin9) character encoding support by converting to UTF-8
  def latin_encoding(pencoding, pdata)
	result = nil
	convert = false
	
	case pencoding
		when 'L1'
			csv_data_lat = Iconv.conv("UTF-8", "ISO8859-1", pdata)
			convert = true

		when 'L9'
			csv_data_lat = Iconv.conv("UTF-8", "ISO8859-15", pdata)
			convert = true
	end
	
	if convert
		result = { :latin => true, :encoding => 'U', :data => csv_data_lat }
	else
		result = { :latin => false }
	end
	
	return result
  end
  
  def import_issues(csv_data, header, encoding, quote_char, col_sep, params)
  
    default_tracker = params[:default_tracker]
    update_issue = params[:update_issue]
    unique_field = params[:unique_field]
    journal_field = params[:journal_field]
    update_other_project = params[:update_other_project]
    ignore_non_exist = params[:ignore_non_exist]
    fields_map = params[:fields_map]
    unique_attr = fields_map[unique_field]
	
    # check params
    if update_issue && unique_attr == nil
      flash[:error] = "Unique field hasn't match an issue's field"
      return
    end
    
    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert
	
	ActiveRecord::Base.transaction do
      FasterCSV.new(csv_data, {:headers=>header, :encoding=>encoding, 
        :quote_char=>quote_char, :col_sep=>col_sep}).each do |row|

	      project = Project.find_by_name(row[attrs_map["project"]])
	      tracker = Tracker.find_by_name(row[attrs_map["tracker"]])
	      status = IssueStatus.find_by_name(row[attrs_map["status"]]) 
	      author = row[attrs_map["author"]] != nil ? User.find_by_login(row[attrs_map["author"]]) : User.current
	      priority = Enumeration.find_by_name(row[attrs_map["priority"]])
	      category = IssueCategory.find_by_name(row[attrs_map["category"]])
	      assigned_to = User.find_by_login(row[attrs_map["assigned_to"]])
	      fixed_version = Version.find_by_name(row[attrs_map["fixed_version"]])
	      # new issue or find exists one
	      issue = Issue.new
	      journal = nil
	      issue.project_id = project != nil ? project.id : @project.id
	      issue.tracker_id = tracker != nil ? tracker.id : default_tracker
	      issue.author_id = author != nil ? author.id : User.current.id
		  
	      if update_issue
	        # custom field
	        if !ISSUE_ATTRS.include?(unique_attr.to_sym)
	          issue.available_custom_fields.each do |cf|
	            if cf.name == unique_attr
	              unique_attr = "cf_#{cf.id}"
	              break
	            end
	          end 
	        end
	        
	        if unique_attr == "id"
	          issues = [Issue.find_by_id(row[unique_field])]
	        else
	          query = Query.new(:name => "_importer", :project => @project)
	          query.add_filter("status_id", "*", [1])
	          query.add_filter(unique_attr, "=", [row[unique_field]])

	          issues = Issue.find :all, :conditions => query.statement,
	          	:limit => 2, :include => [ :assigned_to, :status, :tracker, 
		        :project, :priority, :category, :fixed_version ]
	        end
	        
	        if issues.size > 1
	          flash[:warning] = "Unique field #{unique_field} has duplicate record"
	          @failed_count += 1
	          @failed_events[@handle_count + 1] = row
	          break
	        else
	          if issues.size > 0
	            # found issue
	            issue = issues.first
	            
	            # ignore other project's issue or not
	            if issue.project_id != @project.id && !update_other_project
	              @skip_count += 1
	              next              
	            end
	            
	            # ignore closed issue except reopen
	            if issue.status.is_closed?
	              if status == nil || status.is_closed?
	                @skip_count += 1
	                next
	              end
	            end
	            
	            # init journal
	            note = row[journal_field] || ''
	            journal = issue.init_journal(author || User.current, 
	              note || '')
	              
	            @update_count += 1
	          else
	            # ignore none exist issues
	            if ignore_non_exist
	              @skip_count += 1
	              next
	            end
	          end
	        end
	      end
    
	      # project affect
	      if project == nil
	        project = Project.find_by_id(issue.project_id)
	      end
	      @affect_projects_issues.has_key?(project.name) ?
	        @affect_projects_issues[project.name] += 1 : @affect_projects_issues[project.name] = 1

	      # required attributes
	      issue.status_id = status != nil ? status.id : issue.status_id
	      issue.priority_id = priority != nil ? priority.id : issue.priority_id
	      issue.subject = row[attrs_map["subject"]] || issue.subject
	      
	      # optional attributes
	      issue.description = row[attrs_map["description"]] || issue.description
	      issue.category_id = category != nil ? category.id : issue.category_id
	      issue.start_date = row[attrs_map["start_date"]] || issue.start_date
	      issue.due_date = row[attrs_map["due_date"]] || issue.due_date
	      issue.assigned_to_id = assigned_to != nil ? assigned_to.id : issue.assigned_to_id
	      issue.fixed_version_id = fixed_version != nil ? fixed_version.id : issue.fixed_version_id
	      issue.done_ratio = row[attrs_map["done_ratio"]] || issue.done_ratio
	      issue.estimated_hours = row[attrs_map["estimated_hours"]] || issue.estimated_hours

	      # custom fields
	      issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, c|
	        if value = row[attrs_map[c.name]]
	          h[c.id] = value
	        end
	        h
	      end
		  
	      if (!issue.save)
	        # 记录错误
			
			# Log errors on issue saving
			logger.info "Issue not saved !"
			issue.errors.each_full { |msg| logger.info msg }

	        @failed_count += 1
	        @failed_events[@handle_count + 1] = row
	      end
  
	      if journal
	        journal
	      end
	      
	      @handle_count += 1
		end # do
    end # do
	
    if @failed_events.size > 0
      @failed_events = @failed_events.sort
      @headers = @failed_events[0][1].headers
    end
  end
  
  def import_time_entries(csv_data, header, encoding, quote_char, col_sep) 
    row_counter = 0
    failed_counter = 0

    begin
      ActiveRecord::Base.transaction do
		FasterCSV.new(csv_data, {:headers=>header, :encoding=>encoding,
		  :quote_char=>quote_char, :col_sep=>col_sep}).each do |row|

##        FasterCSV.parse(csv_file) do |row|
          if row[0].blank? ||
              row[2].blank? ||
              row[3].blank? ||
              row[4].blank? ||
              row[5].blank? ||
			  row[6].blank?
            
##		            failed_counter += 1
			@failed_count += 1
	        @failed_events[@handle_count + 1] = row
            next

          end

          custom_field = CustomField.find_by_name(CSV_IMPORT_ID)
          custom_field_value = CustomValue.find(:first, :conditions => ["custom_field_id = ? and value = ?",  
	          custom_field.id,row[0]])

		  issue = Issue.find_by_id(custom_field_value.customized_id)
		  
          @time = TimeEntry.new(:issue_id => issue.id,
                               :spent_on => row[2],
                               :activity => TimeEntryActivity.find_by_name(row[3].strip),
                               :hours => row[4])
          # Truncate comments to 255 chars
          @time.comments = row[1].mb_chars[0..255].strip.to_s if row[1].present?
          @time.user = User.find_by_login(row[5].strip)
		  @time.gct_tpscra = row[6]
		  
          @time.save!
##		         row_counter += 1
		  @handle_count += 1
        end
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => ex
      return "ERROR: #{ex.message} on:\n\n#{@time.inspect}"
    end
	
##    failed_message = failed_counter == 0 ? '' : "#{failed_counter} records failed to import."
##    return "Imported #{row_counter} records. #{failed_message}"
	if @failed_events.size > 0
      @failed_events = @failed_events.sort
      @headers = @failed_events[0][1].headers
    end
  end
  
end
