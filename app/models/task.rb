class Task < ActiveRecord::Base
  include ApplicationHelper
  include LogHelper

  #
  # Permissions around task data
  #
  def self.permissions
    # What can students do with tasks?
    student_role_permissions = [
      :get,
      :put,
      :get_submission,
      :make_submission,
      :delete_own_comment
    ]
    # What can tutors do with tasks?
    tutor_role_permissions = [
      :get,
      :put,
      :get_submission,
      :make_submission,
      :delete_other_comment,
      :delete_own_comment,
      :view_plagiarism,
      :delete_plagiarism
    ]
    # What can convenors do with tasks?
    convenor_role_permissions = [
      :get,
      :get_submission,
      :make_submission,
      :delete_other_comment,
      :delete_own_comment,
      :view_plagiarism,
      :delete_plagiarism
    ]
    # What can nil users do with tasks?
    nil_role_permissions = [

    ]

    # Return permissions hash
    {
      student: student_role_permissions,
      tutor: tutor_role_permissions,
      convenor: convenor_role_permissions,
      nil: nil_role_permissions
    }
  end

  def role_for(user)
    project_role = project.user_role(user)
    return project_role unless project_role.nil?
    logger.debug "Getting role for user #{user.id unless user.nil?}: #{task_definition.abbreviation} #{task_definition.group_set}"
    # check for group member
    if group_task?
      logger.debug 'Checking group'
      if group && group.has_user(user)
        return :group_member
      else
        return nil
      end
    end
  end

  # Model associations
  belongs_to :task_definition       # Foreign key
  belongs_to :project               # Foreign key
  belongs_to :task_status           # Foreign key
  belongs_to :group_submission

  has_many :sub_tasks, dependent: :destroy
  has_many :comments, class_name: 'TaskComment', dependent: :destroy, inverse_of: :task
  has_many :plagiarism_match_links, class_name: 'PlagiarismMatchLink', dependent: :destroy, inverse_of: :task
  has_many :reverse_plagiarism_match_links, class_name: 'PlagiarismMatchLink', dependent: :destroy, inverse_of: :other_task, foreign_key: 'other_task_id'
  has_many :learning_outcome_task_links, dependent: :destroy # links to learning outcomes
  has_many :learning_outcomes, through: :learning_outcome_task_links

  validates :task_definition_id, uniqueness: { scope: :project,
                                               message: 'must be unique within the project' }

  validate :must_have_quality_pts, if: :for_task_with_quality?

  after_save :update_project

  def for_task_with_quality?
    task_definition.max_quality_pts.positive?
  end

  def must_have_quality_pts
    if quality_pts.nil? || quality_pts.negative? || quality_pts > task_definition.max_quality_pts
      errors.add(:quality_pts, "must be between 0 and #{task_definition.max_quality_pts}")
    end
  end

  def all_comments
    if group_submission.nil?
      comments
    else
      TaskComment.joins(:task).where('tasks.group_submission_id = :id', id: group_submission.id)
    end
  end

  def mark_comments_as_read(user, comments)
    comments.each do |comment|
      comment.mark_as_read(user, unit)
    end
  end

  def mark_comments_as_unread(user, comments)
    comments.each do |comment|
      comment.mark_as_unread(user)
    end
  end

  def current_plagiarism_match_links
    plagiarism_match_links.where(dismissed: false)
  end

  def self.for_unit(unit_id)
    Task.joins(:project).where('projects.unit_id = :unit_id', unit_id: unit_id)
  end

  def self.for_user(user)
    Task.joins(:project).where('projects.user_id = ?', user.id)
  end

  delegate :unit, to: :project

  delegate :student, to: :project

  delegate :upload_requirements, to: :task_definition

  def processing_pdf?
    if group_task? && group_submission
      File.exist? File.join(FileHelper.student_work_dir(:new), group_submission.submitter_task.id.to_s)
    else
      File.exist? File.join(FileHelper.student_work_dir(:new), id.to_s)
    end
    # portfolio_evidence == nil && ready_to_mark?
  end

  def update_project
    project.update_attribute(:progress, project.calculate_progress)
    project.update_attribute(:status, project.calculate_status)
  end

  def overdue?
    # A task cannot be overdue if it is marked complete
    return false if complete?

    # Compare the recommended date with the date given to determine
    # if the task is overdue
    recommended_date = task_definition.target_date
    project.reference_date > recommended_date && weeks_overdue >= 1
  end

  def long_overdue?
    # A task cannot be overdue if it is marked complete
    return false if complete?

    # Compare the recommended date with the date given to determine
    # if the task is overdue
    recommended_date = task_definition.target_date
    project.reference_date > recommended_date && weeks_overdue > 2
  end

  def currently_due?
    # A task is currently due if it is not complete and over/under the due date by less than
    # 7 days
    !complete? && days_overdue.between?(-7, 7)
  end

  def weeks_until_due
    days_until_due / 7
  end

  def days_until_due
    (task_definition.target_date - project.reference_date).to_i / 1.day
  end

  def weeks_overdue
    days_overdue / 7
  end

  def days_since_completion
    (project.reference_date - completion_date.to_datetime).to_i / 1.day
  end

  def weeks_since_completion
    days_since_completion / 7
  end

  def days_overdue
    (project.reference_date - task_definition.target_date).to_i / 1.day
  end

  # Action date defines the last time a task has been "actioned", either the
  # submission date or latest student comment -- whichever is newer
  def action_date
    return nil if last_student_comment.nil? || submission_date.nil?
    return last_student_comment.created_at if !last_student_comment.nil? && submission_date.nil?
    return submission_date.created_at      if !submission_date.nil? && last_student_comment.nil?
    last_student_comment.created_at > submission_date ? last_student_comment.created_at : submission_date
  end

  # Returns the last student comment for this task
  def last_student_comment
    comments.where(user: project.user).order(:created_at).last
  end

  # Returns the last tutor comment for this task
  def last_tutor_comment
    comments.where(user: project.tutorial.tutor).order(:created_at).last
  end

  delegate :due_date, to: :task_definition

  delegate :target_date, to: :task_definition

  def complete?
    status == :complete
  end

  def discuss_or_demonstrate?
    status == :discuss || status == :demonstrate
  end

  def discuss?
    status == :discuss
  end

  def demonstrate?
    status == :demonstrate
  end

  def fail?
    status == :fail
  end

  def task_submission_closed?
    complete? || discuss_or_demonstrate? || do_not_resubmit? || fail?
  end

  def ok_to_submit?
    status != :complete && status != :discuss && status != :demonstrate
  end

  def ready_to_mark?
    status == :ready_to_mark
  end

  def ready_or_complete?
    status == :complete || status == :discuss || status == :demonstrate || status == :ready_to_mark
  end

  def fix_and_resubmit?
    status == :fix_and_resubmit
  end

  def do_not_resubmit?
    status == :do_not_resubmit
  end

  def redo?
    status == :redo
  end

  def need_help?
    status == :need_help
  end

  def working_on_it?
    status == :working_on_it
  end

  def reviewable?
    has_pdf && (ready_to_mark? || need_help?)
  end

  def status
    task_status.status_key
  end

  def has_pdf
    !portfolio_evidence.nil? && File.exist?(portfolio_evidence)
  end

  def log_details
    "#{id} - #{project.student.username}, #{project.unit.code}"
  end

  def assign_evidence_path(final_pdf_path, propagate = true)
    if group_task? && propagate
      group_submission.tasks.each do |task|
        task.assign_evidence_path(final_pdf_path, false)
      end
      reload
    else
      logger.debug "Assigning task #{id} to final PDF evidence path #{final_pdf_path}"
      self.portfolio_evidence = final_pdf_path
      logger.debug "PDF evidence path for task #{id} is now #{portfolio_evidence}"
      save
    end
  end

  def group_task?
    !group_submission.nil? || !task_definition.group_set.nil?
  end

  def group
    return nil unless group_task?
    # Cannot use group submission as group may change after submission
    # need to locate group via unit's groups
    project.groups.where(group_set_id: task_definition.group_set_id).first
  end

  def ensured_group_submission
    return nil unless group_task?
    return group_submission unless group_submission.nil?

    group.create_submission self, '', group.projects.map { |proj| { project: proj, pct: 100 / group.projects.count } }
  end

  def trigger_transition(trigger: '', by_user: nil, bulk: false, group_transition: false, quality: 1)
    #
    # Ensure that assessor is allowed to update the task in the indicated way
    #
    role = role_for(by_user)

    return nil if role.nil?

    #
    # Ensure that only staff can change from staff assigned status if
    # this is a restricted task
    #
    return nil if [ :student, :group_member ].include?(role) &&
                  task_definition.restrict_status_updates &&
                  task_status.in?(TaskStatus.staff_assigned_statuses)

    # Protect closed states from student changes
    return nil if [ :student, :group_member ].include?(role) && task_submission_closed?

    #
    # State transitions based upon the trigger
    #

    #
    # Tutor and student can trigger these actions...
    #
    case trigger
    when 'ready_to_mark', 'rtm'
      submit
    when 'not_started'
      engage TaskStatus.not_started
    when 'not_ready_to_mark'
      engage TaskStatus.not_started
    when 'need_help'
      engage TaskStatus.need_help
    when 'working_on_it'
      engage TaskStatus.working_on_it
    else
      #
      # Only tutors can perform these actions
      #
      if role == :tutor
        if task_definition.max_quality_pts > 0
          if %w(complete discuss demonstrate de demo d).include? trigger
            update(quality_pts: quality)
          end
        end

        case trigger
        when 'fail', 'f'
          assess TaskStatus.fail, by_user
        when 'redo'
          assess TaskStatus.redo, by_user
        when 'complete'
          assess TaskStatus.complete, by_user
        when 'fix_and_resubmit', 'fix'
          assess TaskStatus.fix_and_resubmit, by_user
        when 'do_not_resubmit', 'dnr', 'fix_and_include', 'fixinc'
          assess TaskStatus.do_not_resubmit, by_user
        when 'demonstrate', 'de', 'demo'
          assess TaskStatus.demonstrate, by_user
        when 'discuss', 'd'
          assess TaskStatus.discuss, by_user
        end
      end
    end

    # if this is a status change of a group task -- and not already doing group update
    if !group_transition && group_task?
      logger.debug "Group task transition for #{group_submission} set to status #{trigger} (id=#{id})"
      unless [ TaskStatus.working_on_it, TaskStatus.need_help ].include? task_status
        ensured_group_submission.propagate_transition self, trigger, by_user, quality
      end
    end

    # TODO: Remove once task_stats deleted
    # if not bulk then project.calc_task_stats(self) end
    true
  end

  def grade_desc
    case grade
    when 0
      'Pass'
    when 1
      'Credit'
    when 2
      'Distinction'
    when 3
      'High Distinction'
    end
  end

  #
  # Tries to grade the task if it is a graded task
  #
  def grade_task(new_grade, ui = nil, grading_group = false)
    raise_error = lambda do |message|
      ui.error!({ 'error' => message }, 403) unless ui.nil?
      raise message
    end

    grade_map = {
      'p'  => 0,
      'c'  => 1,
      'd'  => 2,
      'hd' => 3
    }
    if task_definition.is_graded
      if new_grade.nil?
        raise_error.call("No grade was supplied for a graded task (task id #{id})")
      else
        # validate (and convert if need be) new_grade
        unless new_grade.is_a?(String) || new_grade.is_a?(Integer)
          raise_error.call("New grade supplied to task is not a string or integer (task id #{id})")
        end
        if new_grade.is_a?(String)
          if grade_map.keys.include?(new_grade.downcase)
            # convert string representation to integer representation
            new_grade = grade_map[new_grade]
          else
            raise_error.call("New grade supplied to task is not an invalid string - expects one of {p|c|d|hd} (task id #{id})")
          end
        end
        unless new_grade.is_a?(Integer) && grade_map.values.include?(new_grade.to_i)
          raise_error.call("New grade supplied to task is not an invalid integer - expects one of {0|1|2|3} (task id #{id})")
        end
        # propagate new grade to all OTHER group members
        if group_task? && !grading_group
          logger.debug "Grading a group submission to grade #{new_grade}"
          ensured_group_submission.propagate_grade self, new_grade, ui
        end

        # now update this task... (may be group task or individual...)
        logger.debug "Grading task #{id} in a group submission to grade #{new_grade}"
        update(grade: new_grade)
      end
    elsif grade?
      raise_error.call("Grade was supplied for a non-graded task (task id #{id})")
    end
  end

  def assess(task_status, assessor, assess_date = Time.zone.now)
    # Set the task's status to the assessment outcome status
    # and flag it as no longer awaiting signoff
    self.task_status = task_status

    # Ensure it has a submission date
    self.submission_date = assess_date if submission_date.nil?

    # Set the assessment date and update the times assessed
    if assessment_date.nil? || assessment_date < submission_date
      # only a new assessment if it was submitted after last assessment
      self.times_assessed += 1
    end
    self.assessment_date = assess_date

    # Set the completion date of the task if it's been completed
    if ready_or_complete?
      self.completion_date = assess_date if completion_date.nil?
    else
      self.completion_date = nil
    end

    # Save the task
    if save!
      # If a task has been completed, that means the project
      # has definitely started
      project.start

      TaskEngagement.create!(task: self, engagement_time: Time.zone.now, engagement: task_status.name)

      # Grab the submission for the task if the user made one
      submission = TaskSubmission.where(task_id: id).order(:submission_time).reverse_order.first
      # Prepare the attributes of the submission
      submission_attributes = { task: self, assessment_time: assess_date, assessor: assessor, outcome: task_status.name }

      # Create or update the submission depending on whether one was made
      if submission.nil?
        submission_attributes[:submission_time] = assess_date
        submission = TaskSubmission.create! submission_attributes
      else
        submission.update_attributes submission_attributes
        submission.save
      end
    end
  end

  def engage(engagement_status)
    self.task_status = engagement_status

    if save!
      TaskEngagement.create!(task: self, engagement_time: Time.zone.now, engagement: task_status.name)
    end
  end

  def submit(submit_date = Time.zone.now)
    self.task_status      = TaskStatus.ready_to_mark
    self.submission_date  = submit_date

    if save!
      project.start
      TaskEngagement.create!(task: self, engagement_time: Time.zone.now, engagement: task_status.name)
      submission = TaskSubmission.where(task_id: id).order(:submission_time).reverse_order.first

      if submission.nil?
        TaskSubmission.create!(task: self, submission_time: submit_date)
      else
        if (!submission.submission_time.nil?) && submit_date < submission.submission_time + 1.hour && submission.assessor.nil?
          # update old submission if within time window
          submission.submission_time = submit_date
          submission.save!
        else
          TaskSubmission.create!(task: self, submission_time: submit_date)
        end
      end
    end
  end

  def assessed?
    redo? ||
      fix_and_resubmit? ||
      do_not_resubmit? ||
      fail? ||
      complete?
  end

  def weight
    task_definition.weighting.to_f
  end

  def add_comment(user, text)
    text.strip!
    return nil if user.nil? || text.nil? || text.empty?

    lc = comments.last
    return if lc && lc.user == user && lc.comment == text

    ensured_group_submission if group_task?

    comment = TaskComment.create
    comment.task = self
    comment.user = user
    comment.comment = text
    comment.recipient = user == project.student ? project.main_tutor : project.student
    comment.save!
    comment
  end

  def last_comment
    all_comments.last
  end

  def last_comment_by(user)
    result = all_comments.where(user: user).last

    return '' if result.nil?
    result.comment
  end

  def has_comment_by(user)
    !last_comment_by(user).empty?
  end

  def is_last_comment_by?(user)
    last_comment = all_comments.last
    return false if last_comment.nil?

    last_comment.user == user
  end

  def last_comment_not_by(user)
    result = all_comments.where('user_id != :id', id: user.id).last

    return '' if result.nil?
    result.comment
  end

  # Indicates what is the largest % similarity is for this task
  def pct_similar
    if current_plagiarism_match_links.order(pct: :desc).first.nil?
      0
    else
      current_plagiarism_match_links.order(pct: :desc).first.pct
    end
  end

  def similar_to_count
    plagiarism_match_links.count
  end

  def similar_to_dismissed_count
    plagiarism_match_links.where('dismissed = TRUE').count
  end

  def recalculate_max_similar_pct
    # TODO: Remove once max_pct_similar is deleted
    # self.max_pct_similar = pct_similar()
    # self.save
    #
    # project.recalculate_max_similar_pct()
  end

  delegate :name, to: :task_definition

  def student_work_dir(type, create = true)
    if group_task?
      FileHelper.student_group_work_dir(type, group_submission, group_submission.submitter_task, create)
    else
      FileHelper.student_work_dir(type, self, create)
    end
  end

  def zip_file_path_for_done_task
    if group_task?
      if group_submission.nil?
        nil
      else
        "#{FileHelper.student_group_work_dir(:done, group_submission)[0..-2]}.zip"
      end
    else
      "#{student_work_dir(:done, false)[0..-2]}.zip"
    end
  end

  def extract_file_from_done(to_path, pattern, name_fn)
    zip_file = zip_file_path_for_done_task
    return false if zip_file.nil? || (!File.exist? zip_file)

    Zip::File.open(zip_file) do |zip|
      # Extract folders
      zip.each do |entry|
        # Extract to file/directory/symlink
        logger.debug "Extracting file from done: #{entry.name}"
        if entry.name_is_directory?
          entry.extract(name_fn.call(self, to_path, entry.name)) { true }
        end
      end
      zip.glob("**/#{pattern}").each do |entry|
        entry.extract(name_fn.call(self, to_path, entry.name)) { true }
      end
    end
  end

  #
  # Compress the done files for a student - includes cover page and work uploaded
  #
  def compress_new_to_done
    task_dir = student_work_dir(:new, false)
    begin
      zip_file = zip_file_path_for_done_task
      return false if zip_file.nil? || (!Dir.exist? task_dir)

      FileUtils.rm(zip_file) if File.exist? zip_file

      # compress image files
      image_files = Dir.entries(task_dir).select { |f| (f =~ /^\d{3}.(image)/) == 0 }
      image_files.each do |img|
        return false unless FileHelper.compress_image("#{task_dir}#{img}")
      end

      # copy all files into zip
      input_files = Dir.entries(task_dir).select { |f| (f =~ /^\d{3}.(cover|document|code|image)/) == 0 }

      zip_dir = File.dirname(zip_file)
      FileUtils.mkdir_p zip_dir unless Dir.exist? zip_dir

      Zip::File.open(zip_file, Zip::File::CREATE) do |zip|
        zip.mkdir id.to_s
        input_files.each do |in_file|
          zip.add "#{id}/#{in_file}", "#{task_dir}#{in_file}"
        end
      end
    ensure
      FileUtils.rm_rf(task_dir)
    end

    true
  end

  def clear_in_process
    in_process_dir = student_work_dir(:in_process, false)
    if Dir.exist? in_process_dir
      Dir.chdir(FileUtils.student_work_dir) if FileUtils.pwd == in_process_dir
      FileUtils.rm_rf in_process_dir
    end
  end

  #
  # Move folder over from done -> new
  # Allowing task pdf to be recreated next time pdfs are generated
  #
  def move_done_to_new
    done = student_work_dir(:done, false)

    if Dir.exist? done
      new_task_dir = student_work_dir(:new, false)
      FileUtils.mkdir_p(new_task_dir)
      FileHelper.move_files(done, new_task_dir)
      true
    elsif FileHelper.move_compressed_task_to_new(self)
      true
    else
      false
    end
  end

  #
  # Move folder over from new or done -> in_process returns true on success
  #
  def move_files_to_in_process
    # find and clear out old dir
    in_process_dir = student_work_dir(:in_process, false)

    return false if in_process_dir.nil?

    if Dir.exist? in_process_dir
      pwd = FileUtils.pwd
      Dir.chdir(in_process_dir)
      # move all files to the enq dir
      FileUtils.rm Dir.glob('*')
      Dir.chdir(pwd)
    end

    from_dir = student_work_dir(:new, false)
    if Dir.exist?(from_dir)
      # save new files in done folder
      return false unless compress_new_to_done
    end

    zip_file = zip_file_path_for_done_task
    if zip_file && File.exist?(zip_file)
      extract_file_from_done FileHelper.student_work_dir(:new), '*', lambda { |_task, to_path, name|
        "#{to_path}#{name}"
      }
      return false unless Dir.exist?(from_dir)
    else
      return false
    end

    # Move files from new to in process
    FileHelper.move_files(from_dir, in_process_dir)
    true
  end

  def __output_filename__(in_dir, idx, type)
    pwd = FileUtils.pwd
    Dir.chdir(in_dir)
    begin
      # Rename files with 000.type.* to 000-type-*
      result = Dir.glob("#{idx.to_s.rjust(3, '0')}.#{type}.*").first

      if !result.nil? && File.exist?(result)
        FileUtils.mv result, "#{idx.to_s.rjust(3, '0')}-#{type}#{File.extname(result)}"
      end
      result = Dir.glob("#{idx.to_s.rjust(3, '0')}-#{type}.*").first
    ensure
      Dir.chdir(pwd)
    end

    return File.join(in_dir, result) unless result.nil?
    nil
  end

  def in_process_files_for_task(is_retry)
    magic = FileMagic.new(FileMagic::MAGIC_MIME)
    in_process_dir = student_work_dir(:in_process, false)
    return [] unless Dir.exist? in_process_dir

    result = []

    idx = 0
    upload_requirements.each do |file_req|
      output_filename = __output_filename__(in_process_dir, idx, file_req['type'])

      if output_filename.nil?
        idx += 1 # skip headers if present
        output_filename = __output_filename__(in_process_dir, idx, file_req['type'])
      end

      if output_filename.nil?
        logger.error "Error processing task #{log_details} - missing file #{file_req}"
        raise "File `#{file_req['name']}` missing from submission."
      else
        result << { path: output_filename, type: file_req['type'] }

        if file_req['type'] == 'code'
          # convert utf-16 to utf-8
          # TODO: avoid system call... if we can work out how to get ruby to save as UTF8
          # Encode fails... if the file is read with invalid encoding...
          
          # So... read encoding using file
          encoding = `file --brief --mime-encoding #{output_filename}`.strip

          # Convert to utf8 from read encoding
          if is_retry
            `iconv -c -f #{encoding} -t UTF-8 "#{output_filename}" > new`
          else
            `iconv -c -f #{encoding} -t ascii "#{output_filename}" > new`
          end

          # Read the contents
          file = File.open("new", "r") 
          content = file.read.encode().encode("UTF-8", { invalid: :replace, undef: :replace, replace: '?'} )
          file.close()
          # Strip BOM
          content.gsub!("\xEF\xBB\xBF".force_encoding("UTF-8"), '')

          # Write contents
          File.open("new", 'w') { |file| file.write(content) }

          # Move into place
          FileUtils.mv('new', output_filename)
        end

        idx += 1 # next file index
      end
    end

    result
  end

  class TaskAppController < ApplicationController
    attr_accessor :task
    attr_accessor :files
    attr_accessor :base_path
    attr_accessor :image_path

    def init(task, is_retry)
      @task = task
      @files = task.in_process_files_for_task(is_retry)
      @base_path = task.student_work_dir(:in_process, false)
      @image_path = Rails.root.join('public', 'assets', 'images')
      @institution_name = Doubtfire::Application.config.institution[:name]
    end

    def make_pdf
      render_to_string(template: '/task/task_pdf.pdf.erb', layout: true)
    end
  end

  def self.pygments_lang(extn)
    extn = extn.downcase
    if %w(pas pp).include?(extn) then 'pas'
    elsif ['cs'].include?(extn) then 'csharp'
    elsif %w(c h idc).include?(extn) then 'c'
    elsif ['cpp', 'hpp', 'c++', 'h++', 'cc', 'cxx', 'cp'].include?(extn) then 'cpp'
    elsif ['java'].include?(extn) then 'java'
    elsif ['js'].include?(extn) then 'js'
    elsif ['html'].include?(extn) then 'html'
    elsif ['css'].include?(extn) then 'css'
    elsif ['rb'].include?(extn) then 'ruby'
    elsif ['coffee'].include?(extn) then 'coffeescript'
    elsif %w(yaml yml).include?(extn) then 'yaml'
    elsif ['xml'].include?(extn) then 'xml'
    elsif ['scss'].include?(extn) then 'scss'
    elsif ['json'].include?(extn) then 'json'
    elsif ['ts'].include?(extn) then 'ts'
    elsif ['sql'].include?(extn) then 'sql'
    elsif ['vb'].include?(extn) then 'vbnet'
    elsif ['txt'].include?(extn) then 'text'
    else 'text'
    end
  end

  def final_pdf_path
    if group_task?
      return nil if group_submission.nil? || group_submission.task_definition.nil?

      File.join(
        FileHelper.student_group_work_dir(:pdf, group_submission, task = nil, create = true),
        FileHelper.sanitized_filename(FileHelper.sanitized_path("#{group_submission.task_definition.abbreviation}-#{group_submission.id}") + '.pdf')
      )
    else
      File.join(student_work_dir(:pdf), FileHelper.sanitized_filename(FileHelper.sanitized_path("#{task_definition.abbreviation}-#{id}") + '.pdf'))
    end
  end

  def convert_submission_to_pdf
    return false unless move_files_to_in_process

    begin
      tac = TaskAppController.new
      tac.init(self, false)

      begin
        pdf_text = tac.make_pdf
      rescue => e

        # Try again... with convert to ascii
        tac2 = TaskAppController.new
        tac2.init(self, true)

        begin
          pdf_text = tac2.make_pdf
        rescue => e2
          logger.error "Failed to create PDF for task #{log_details}. Error: #{e.message}"

          log_file = e.message.scan(/\/.*\.log/).first
          # puts "log file is ... #{log_file}"
          if log_file && File.exist?(log_file)
            # puts "exists"
            begin
              puts "--- Latex Log ---\n"
              puts File.read(log_file)
              puts "---    End    ---\n\n"
            rescue
            end
          end

          raise 'Failed to convert your submission to PDF. Check code files submitted for invalid characters, that documents are valid pdfs, and that images are valid.'
        end
      end

      if group_task?
        group_submission.tasks.each do |t|
          t.portfolio_evidence = final_pdf_path
          t.save
        end
        reload
      else
        self.portfolio_evidence = final_pdf_path
      end

      File.open(portfolio_evidence, 'w') do |fout|
        fout.puts pdf_text
      end

      FileHelper.compress_pdf(portfolio_evidence)

      save

      clear_in_process
      return true
    rescue => e
      clear_in_process

      trigger_transition trigger: 'fix', by_user: project.main_tutor
      raise e
    end
  end

  #
  # The student has uploaded new work...
  #
  def create_submission_and_trigger_state_change(user, propagate = true, contributions = nil, trigger = 'ready_to_mark')
    if group_task? && propagate
      if contributions.nil? # even distribution
        contribs = group.projects.map { |proj| { project: proj, pct: 100 / group.projects.count, pts: 3 } }
      else
        contribs = contributions.map { |data| { project: Project.find(data[:project_id]), pct: data[:pct].to_i, pts: data[:pts].to_i } }
      end
      group_submission = group.create_submission self, "#{user.name} has submitted work", contribs
      group_submission.tasks.each { |t| t.create_submission_and_trigger_state_change(user, propagate = false) }
      reload
    else
      self.file_uploaded_at = Time.zone.now
      self.submission_date = Time.zone.now

      # This task is now ready to submit
      unless discuss_or_demonstrate? || complete? || do_not_resubmit? || fail?
        trigger_transition trigger: trigger, by_user: user, group_transition: false

        plagiarism_match_links.each(&:destroy)
        reverse_plagiarism_match_links(&:destroy)
      end
      save
    end
  end

  #
  # Create alignments on submission
  #
  def create_alignments_from_submission(current_user, alignments)
    # Remove existing alignments no longer applicable
    LearningOutcomeTaskLink.where(task_id: id).delete_all()
    alignments.each do |alignment|
      link = LearningOutcomeTaskLink.find_or_create_by(
        task_definition_id: task_definition.id,
        learning_outcome_id: alignment.ilo_id,
        task_id: id
      )
      link.rating = alignment.rating
      link.description = alignment.rationale
      link.save!
    end
  end

  #
  # Moves submission into place
  #
  def accept_submission(current_user, files, _student, ui, contributions, trigger, alignments)
    #
    # Ensure that each file in files has the following attributes:
    # id, name, filename, type, tempfile
    #
    files.each do |file|
      ui.error!({ 'error' => "Missing file data for '#{file.name}'" }, 403) if file.id.nil? || file.name.nil? || file.filename.nil? || file.type.nil? || file.tempfile.nil?
    end

    # Ensure group if group task
    if group_task? && group.nil?
      ui.error!({ 'error' => 'You must be in a group to submit this task.' }, 403)
    end

    # Ensure not already submitted if group task
    if group_task? && group_submission && group_submission.processing_pdf? && group_submission.submitter_task != self
      ui.error!({ 'error' => "#{group_submission.submitter_task.project.student.name} has just submitted this task. Only one team member needs to submit this task, so check back soon to see what was uploaded." }, 403)
    end
    # file.key            = "file0"
    # file.name           = front end name for file
    # file.tempfile.path  = actual file dir
    # file.filename       = their name for the file

    #
    # Confirm subtype categories using filemagic
    #
    files.each_with_index do |file, index|
      logger.debug "Accepting submission (file #{index + 1} of #{files.length}) - checking file type for #{file.tempfile.path}"
      unless FileHelper.accept_file(file, file.name, file.type)
        ui.error!({ 'error' => "'#{file.name}' is not a valid #{file.type} file" }, 403)
      end

      if File.size(file.tempfile.path) > 5_000_000
        ui.error!({ 'error' => "'#{file.name}' exceeds the 5MB file limit. Try compressing or reformat and submit again." }, 403)
      end
    end

    create_alignments_from_submission(current_user, alignments) unless alignments.nil?
    create_submission_and_trigger_state_change(current_user, propagate = true, contributions = contributions, trigger = trigger)

    #
    # Create student submission folder (<tmpdir>/doubtfire/new/<id>)
    #
    tmp_dir = File.join(Dir.tmpdir, 'doubtfire', 'new', id.to_s)
    logger.debug "Creating temporary directory for new dubmission at #{tmp_dir}"

    # ensure the dir exists
    FileUtils.mkdir_p(tmp_dir)

    #
    # Set portfolio_evidence to nil while it gets processed
    #
    portfolio_evidence = nil

    files.each_with_index.map do |file, idx|
      output_filename = File.join(tmp_dir, "#{idx.to_s.rjust(3, '0')}-#{file.type}#{File.extname(file.filename).downcase}")
      FileUtils.cp file.tempfile.path, output_filename
    end

    #
    # Now copy over the temp directory over to the enqueued directory
    #
    enqueued_dir = student_work_dir(:new, self)[0..-2]

    logger.debug "Moving submission evidence from #{tmp_dir} to #{enqueued_dir}"

    pwd = FileUtils.pwd
    # move to tmp dir
    Dir.chdir(tmp_dir)
    # move all files to the enq dir
    FileUtils.mv Dir.glob('*'), enqueued_dir
    # FileUtils.rm Dir.glob("*")
    # remove the directory
    Dir.chdir(pwd)
    Dir.rmdir(tmp_dir)

    logger.debug "Submission accepted! Status for task #{id} is now #{trigger}"
  end
end
