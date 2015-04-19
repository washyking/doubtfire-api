# getting file MIME types
require 'filemagic'
# image to pdf
require 'RMagick'
# code to html
require 'coderay'
# html to pdf
require 'pdfkit'
# zipping files
require 'zip'

module Api::Submission::GenerateHelpers

  def logger
    # Grape::API.logger
    Rails.logger
  end

  #
  # Scoops out a files array from the params provided
  #
  def scoop_files(params, upload_reqs)
    files = params.reject { | key | not key =~ /^file\d+$/ }

    error!({"error" => "Upload requirements mismatch with files provided"}, 403) if files.length != upload_reqs.length 
    #
    # Pair the name and type from upload_requirements to each file
    #
    upload_reqs.each do | detail |
      key = detail['key']
      if files.has_key? key
        files[key].id   = files[key].name
        files[key].name = detail['name']
        files[key].type = detail['type']
      end
    end
    
    # File didn't get assigned an id above, then reject it since there was a mismatch
    files = files.reject { | key, file | file.id.nil? }
    error!({"error" => "Upload requirements mismatch with files provided"}, 403) if files.length != upload_reqs.length 

    # Kill the kvp
    files.map{ | k, v | v }
  end

  def mark_col
    "ready_to_mark (rtm)|discuss (d)|fix_and_resubmit (fix)|fix_and_include (fixinc)|redo"
  end

  #
  # Defines the csv headers for batch download
  #
  def mark_csv_headers
    "Username,Name,Tutorial,Task,ID,student comment,my comment,#{mark_col},comment"
  end
  
  #
  # Generates a download package of the given tasks
  #
  def generate_batch_task_zip(user, tasks, unit)
    download_id = "#{Time.new.strftime("%Y-%m-%d")}-#{unit.code}-#{current_user.username}"
    filename = FileHelper.sanitized_filename("batch_ready_to_mark_#{current_user.username}.zip")
    output_zip = Tempfile.new(filename)
    # Create a new zip
    Zip::File.open(output_zip.path, Zip::File::CREATE) do | zip |
      csv_str = mark_csv_headers
      tasks.each  do | task |
        # Skip tasks that do not yet have a PDF generated
        next if task.processing_pdf
        # Add to the template entry string
        student = task.project.student
        csv_str << "\n#{student.username.sub(/,/, '_')},#{student.name.sub(/,/, '_')},#{task.project.unit_role.tutorial.abbreviation},#{task.task_definition.abbreviation.sub(/,/, '_')},#{task.id},\"#{task.last_comment_by(task.project.student)}\",\"#{task.last_comment_by(user)}\",rtm,"
        
        src_path = task.portfolio_evidence

        next unless File.exists? src_path

        # make dst path of "<student id>/<task abbrev>.pdf"
        dst_path = FileHelper.sanitized_path("#{task.project.student.username}", "#{task.task_definition.abbreviation}-#{task.id}") + ".pdf"
        # now copy it over
        zip.add(dst_path, src_path)
      end
      # Add marking file
      zip.get_output_stream("marks.csv") { | f | f.puts csv_str }
    end
    output_zip
  end

  #
  # Uploads a batch package back into doubtfire
  #
  def upload_batch_task_zip(file)
    fm = FileMagic.new(FileMagic::MAGIC_MIME)

    updated_tasks = []
    ignore_files = []
    error_tasks = []

    done = {}

    mime_type = fm.file(file.tempfile.path)

    # check mime is correct before uploading
    accept = ['application/zip', 'multipart/x-gzip', 'multipart/x-zip', 'application/x-gzip', 'application/octet-stream']
    if not mime_type.start_with?(*accept)
      error!({"error" => "File given is not a zip file - detected #{mime_type}"}, 403)
    end

    # files are extracted to a temp dir first
    i = 0
    tmp_dir = File.join( Dir.tmpdir, 'doubtfire', 'batch', "#{i}" )

    while Dir.exists? tmp_dir do
      i += 1
      tmp_dir = File.join( Dir.tmpdir, 'doubtfire', 'batch', "#{i}" )
    end

    #puts tmp_dir

    FileUtils.mkdir_p(tmp_dir)

    begin
      Zip::File.open(file.tempfile.path) do |zip|
        # Find the marking file within the directory tree
        marking_file = zip.glob("**/marks.csv").first
        # No marking file found
        if marking_file.nil?
          error!({"error" => "No marks.csv contained in zip"}, 403)
        end
        csv_str = marking_file.get_input_stream.read

        # read keys from CSV
        entry_data = CSV.parse(csv_str, {:headers => true, :header_converters => [:downcase]})

        # Copy over the updated/marked files to the file system
        zip.each do |file|
          # Skip processing marking file
          next if File.basename(file.name) == "marks.csv"

          # Test filename pattern
          if (/.*-\d+.pdf/ =~ File.basename(file.name)) != 0
            if file.name[-1] != '/'
              ignore_files << { file: file.name }
            end
            next
          end
          if (/\._.*/ =~ File.basename(file.name)) == 0
            ignore_files << { file: file.name }
            next
          end

          # Extract the id from the filename
          task_id_from_filename = File.basename(file.name, ".pdf").split('-').last
          task = Task.find_by_id(task_id_from_filename)
          if task.nil?
            ignore_files << { file: file.name }
            next
          end

          # Ensure that this task's id is inside entry_data
          task_entry = entry_data.select{ | t | t['id'] == task.id.to_s }.first
          if task_entry.nil?
            # error!({"error" => "File #{file.name} has a mismatch of task id ##{task.id} (this task id does not exist in marks.csv)"}, 403)
            error_tasks << { file: file.name, error: "Task id #{task.id} not in marks.csv"}
            next
          end
          # Ensure that this task's student matches that in entry_data
          if task_entry['username'] != task.project.student.username
            # error!({"error" => "File #{file.name} has a mismatch of student id (task with id #{task.id} matches student #{task.project.student.username}, not that in marks.csv of #{t['id']}"}, 403)
            error_tasks << { file: file.name, error: "Student mismatch (expected task #{task.id} to matche #{task.project.student.username}, was #{task_entry['username']} in marks.csv"}
            next
          end
          
          # Update the task to whatever its associative mark was 
          valid_marks = %w(ready_to_mark rtm redo fix_and_resubmit fix fix_and_include fixinc discuss d)
          if task_entry[mark_col].nil? or not valid_marks.include? task_entry[mark_col].strip
            msg = task_entry[mark_col].nil? ? "it is missing a mark value in marks.csv" : "acceptable mark codes: #{valid_marks.join ' '}"
            # error!({"error" => "Task id #{task.id} has an invalid mark (#{msg})"}, 403)
            error_tasks << { file: file.name, error: "Task id #{task.id} has an invalid mark (#{msg})"}
            next
          end
          
          # Can the user assess this task?
          if not authorise? current_user, task, :put
            error_tasks << { file: file.name, error: "You do not have permission to assess task with id #{task.id}"}
            next
          end

          # Read into the task's portfolio_evidence path the new file
          tmp_file = File.join(tmp_dir, File.basename(file.name))
          task.portfolio_evidence = PortfolioEvidence.final_pdf_path_for(task)
          # get file out of zip... to tmp_file
          file.extract(tmp_file){ true }

          # copy tmp_file to dest
          if FileHelper.copy_pdf(tmp_file, task.portfolio_evidence)
            task.trigger_transition(task_entry[mark_col], current_user) # saves task
            updated_tasks << { file: file.name }
            if not (task_entry['comment'].nil? || task_entry['comment'].empty?)
              task.add_comment current_user, task_entry['comment']
            end
            FileUtils.rm tmp_file
          else
            error_tasks << { file: file.name, error: 'Invalid pdf' }
            next
          end

          # add to done projects for emailing
          if done[task.project].nil?
            done[task.project] = []
          end
          done[task.project] << task
        end
      end
    rescue
      # FileUtils.cp(file.tempfile.path, Doubtfire::Application.config.student_work_dir)
      raise
    end

    # send emails...
    begin
      done.each do |project, tasks|
        logger.info "checking feedback email for project #{project.id}"
        if project.student.receive_feedback_notifications
          logger.info "emailing feedback notification to #{project.student.name}"
          PortfolioEvidenceMailer.task_feedback_ready(project, tasks).deliver
        end
      end
    rescue => e
      logger.error "failed to send emails from feedback submission: #{e.message}"
    end


    # Remove the extract dir
    FileUtils.rm_rf tmp_dir
    
    {
      succeeded:  updated_tasks,
      ignored:    ignore_files,
      failed:     error_tasks
    }
  end
  
  # module_function :combine_to_pdf
  module_function :scoop_files
  module_function :upload_batch_task_zip
  module_function :generate_batch_task_zip
  
end