class UnitRole < ActiveRecord::Base
  # Model associations
  belongs_to :unit    # Foreign key
  belongs_to :user    # Foreign key

  belongs_to :role    # Foreign key

  belongs_to :tutorial # for students only! TODO: fix

  has_many :taught_tutorials, class_name: 'Tutorial', dependent: :nullify

  validates :unit_id, presence: true
  validates :user_id, presence: true
  validates :role_id, presence: true

  scope :tutors,    -> { joins(:role).where('roles.name = :role', role: 'Tutor') }
  scope :convenors, -> { joins(:role).where('roles.name = :role', role: 'Convenor') }
  # scope :staff,     -> { where('role_id != ?', 1) }

  def self.for_user(user)
    UnitRole.joins(:role, :unit).where("user_id = :user_id and roles.name <> 'Student'", user_id: user.id)
  end

  # unit roles are now unique for users in units
  # TODO: check this usage
  def other_roles
    []
  end

  #
  # Permissions around unit role data
  #
  def self.permissions
    # What can students do with unit roles?
    student_role_permissions = [
      :get
    ]
    # What can tutors do with unit roles?
    tutor_role_permissions = [
      :get
    ]
    # What can convenors do with unit roles?
    convenor_role_permissions = [
      :get,
      :delete
    ]
    # What can nil users do with unit roles?
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

  def self.tasks_to_review(user)
    Tutorial.find_by_user(user)
            .map(&:projects)
            .flatten
            .map(&:tasks)
            .flatten
            .select(&:reviewable?)
  end

  def role_for(user)
    unit_role = unit.role_for(user)
    unit_role = nil if unit_role == Role.student && self.user != user
    unit_role
  end

  def is_tutor?
    role == Role.tutor
  end

  def is_student?
    role == Role.student
  end

  def is_convenor?
    role == Role.convenor
  end

  def is_teacher?
    is_tutor? || is_convenor?
  end
end
