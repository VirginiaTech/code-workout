# == Schema Information
#
# Table name: users
#
#  id                       :integer          not null, primary key
#  email                    :string(255)      default(""), not null
#  encrypted_password       :string(255)      default(""), not null
#  reset_password_token     :string(255)
#  reset_password_sent_at   :datetime
#  remember_created_at      :datetime
#  sign_in_count            :integer          default(0), not null
#  current_sign_in_at       :datetime
#  last_sign_in_at          :datetime
#  current_sign_in_ip       :string(255)
#  last_sign_in_ip          :string(255)
#  confirmation_token       :string(255)
#  confirmed_at             :datetime
#  confirmation_sent_at     :datetime
#  created_at               :datetime
#  updated_at               :datetime
#  first_name               :string(255)
#  last_name                :string(255)
#  global_role_id           :integer          not null
#  avatar                   :string(255)
#  slug                     :string(255)      not null
#  time_zone_id             :integer
#  current_workout_score_id :integer
#  user_group_id            :integer
#
# Indexes
#
#  index_users_on_confirmation_token        (confirmation_token) UNIQUE
#  index_users_on_current_workout_score_id  (current_workout_score_id) UNIQUE
#  index_users_on_email                     (email) UNIQUE
#  index_users_on_global_role_id            (global_role_id)
#  index_users_on_reset_password_token      (reset_password_token) UNIQUE
#  index_users_on_slug                      (slug) UNIQUE
#  index_users_on_time_zone_id              (time_zone_id)
#  index_users_on_user_group_id             (user_group_id)
#

# =============================================================================
# Represents a single user account on the system.
#
class User < ActiveRecord::Base
  include Gravtastic
  gravtastic secure: true, default: 'monsterid'

  extend FriendlyId
  friendly_id :email_or_id


  #~ Relationships ............................................................

  belongs_to  :global_role
  belongs_to  :time_zone
#  has_many    :authentications
#  has_many    :activity_logs
  has_many    :course_enrollments,
    -> { includes :course_role, :course_offering },
   inverse_of: :user, dependent: :destroy
  has_many    :course_offerings, through: :course_enrollments
  has_many    :workout_scores, -> { includes :workout },
    inverse_of: :user, dependent: :destroy
  has_many    :workouts, through: :workout_scores
  has_many    :exercise_owners, inverse_of: :owner
  has_many    :exercises, through: :exercise_owners
  has_many    :workout_owners, inverse_of: :owner
  has_many    :workouts, through: :workout_owners
  has_many    :attempts, dependent: :destroy
  has_many    :tag_user_scores, -> { includes :tag },
    inverse_of: :user, dependent: :destroy
  has_many    :resource_files, inverse_of: :user
  has_many    :identities, inverse_of: :user, dependent: :destroy
  has_many    :student_extensions
  has_many    :workout_offerings, through: :student_extensions

  belongs_to  :current_workout_score, class_name: 'WorkoutScore'
  has_many    :test_case_results, inverse_of: :user, dependent: :destroy
  has_many    :lti_identities

  has_many :memberships
  has_many :user_groups, through: :memberships
  has_many :group_access_requests, inverse_of: :user
  has_one :exercise_collection

  accepts_nested_attributes_for :memberships
  #~ Hooks ....................................................................

  delegate :can?, :cannot?, to: :ability

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, and :timeoutable
  devise :database_authenticatable, :omniauthable, :registerable,
    :recoverable, :rememberable, :trackable, #:validatable,  # :confirmable,
    :omniauth_providers => [:facebook, :google_oauth2, :cas]

  before_create :set_default_role

  paginates_per 100

  scope :search, lambda { |query|
    unless query.blank?
      arel = self.arel_table
      pattern = "%#{query}%"
      where(arel[:email].matches(pattern).or(
            arel[:last_name].matches(pattern)).or(
            arel[:last_name].matches(pattern)))
    end
  }

  scope :alphabetical, -> { order('last_name asc, first_name asc, email asc') }
  scope :visible_to_user, -> (u) { joins{course_enrollments.outer}.
    where{ (id == u.id) |
    (course_enrollments.course_role_id != CourseRole::STUDENT_ID) } }

  attr_accessor :skip_password_validation

  #~ Class methods ............................................................

  # -------------------------------------------------------------
  def self.all_emails(prefix = '')
    self.uniq.where(self.arel_table[:email].matches(
      "#{prefix}%")).reorder('email asc').pluck(:email)
  end

  def self.not_in_group(user_group)
    if user_group.nil?
      User.all
    else
      User.where.not(id: user_group.users.flat_map(&:id))
    end
  end

  #~ Instance methods .........................................................

  # -------------------------------------------------------------
  #  def storage_path
  #    File.join(
  #    SystemConfiguration.first.storage_path, 'users', email)
  #  end


  # -------------------------------------------------------------
  def ability
    @ability ||= Ability.new(self)
  end

  def is_a_member_of?(user_group)
    user_groups.include?(user_group)
  end

  def access_request_for(user_group)
    GroupAccessRequest.find_by user: self, user_group: user_group
  end

  # -------------------------------------------------------------
  # Public: Gets a relation representing all of the CourseOfferings that
  # this user can manage. If a course and term are passed,
  # filters the list by course and term as well.
  #
  # Returns a relation representing all of the CourseOfferings that this
  # user can manage
  # params = {term, course} (optional)
  #
  def managed_course_offerings(options = {})
    course = options[:course]
    term = options[:term]
    if course.nil? && term.nil?
      course_enrollments.where(course_roles: { can_manage_course: true }).
        map(&:course_offering)
    elsif course.nil?
      course_enrollments.joins(:course_offering).
        where(course_roles:
          { can_manage_course: true }, course_offering:
            { term: term }
        ).map(&:course_offering)
    elsif term.nil?
      course_enrollments.joins(:course_offering).
        where(course_roles:
          { can_manage_course: true }, course_offering:
            { course: course }
        ).map(&:course_offering)
    else
      course_enrollments.joins(:course_offering).
        where(course_roles:
          { can_manage_course: true }, course_offering:
            { course: course, term: term }
        ).map(&:course_offering)
    end
  end

  # -------------------------------------------------------------
  def instructor_course_offerings
    course_enrollments.where(course_role: CourseRole.instructor).
      map(&:course_offering)
  end


  # -------------------------------------------------------------
  def grader_course_offerings
    course_enrollments.where(course_role: CourseRole.grader).
      map(&:course_offering)
  end


  # -------------------------------------------------------------
  def student_course_offerings
    course_enrollments.where(course_role: CourseRole.student).
      map(&:course_offering)
  end

  # Get all workout offerings from course offerings that the
  # user manages, for the specified course and term
  def managed_workout_offerings_in_term(workout, course, term)
    if !term.nil?
      enrollments = course_enrollments.joins(course_offering: :workout_offerings).
        where(course_roles:
          { can_manage_course: true }, course_offering:
            { course: course, term: term }
        )
      else
        enrollments = course_enrollments.joins(course_offering: :workout_offerings).
          where(course_roles:
            { can_manage_course: true }, course_offering:
              { course: course }
            )
      end

      enrollments.map { |e|
        if workout.kind_of?(String)
          workouts_with_name = Workout.where('lower(name) = ?', workout)
          e.course_offering.workout_offerings.where{ workout_id.in(workouts_with_name.select{id})}
        else
          e.course_offering.workout_offerings.where(workout: workout)
        end
      }
  end

  # Get all workouts that have been offered in a course
  # for which the user has been an instructor AND for which
  # the user is in the privileged group
  # Simply being an instructor in the course is not enough,
  # to prevent users from simply creating `fake` course_offerings
  # to get access to course materials
  def managed_workouts
    course_enrollments.joins(course_offering: { course: { user_group: :memberships } }).
      where(course_roles:
        { can_manage_course: true }, course_offering:
          { course:
            { user_group:
              { memberships:
                { user: self } } } }
      ).flat_map { |e| e.course_offering.workout_offerings }.map(&:workout)
  end

  # -------------------------------------------------------------
  def course_offerings_for_term(term, course)
    conditions = { term: term, 'users.id' => self }
    if course
      conditions[:course] = course
    end
    CourseOffering.
      joins(course_enrollments: :user).
      where(conditions).
      distinct
  end


  # -------------------------------------------------------------
  def courses_for_term(term)
    Course.
      joins(course_offerings: { course_enrollments: :user }).
      where('course_offerings.term_id' => term, 'users.id' => self).
      distinct
  end


  # -------------------------------------------------------------
  # Gets the user's "display name", which is their full name if it is in the
  # database, otherwise it is their e-mail address.
  def display_name
    last_name.blank? ?
      (first_name.blank? ? email : first_name) :
      (first_name.blank? ? last_name : (first_name + ' ' + last_name))
  end

  # -------------------------------------------------------------
  # Gets the user's "label name", which is their last name, first name, or email_without_domain,
  # in decreasing order of preference. For use in auto-generated course_offering labels
  def label_name
    last_name.blank? ?
      (first_name.blank? ? email_without_domain : first_name) : last_name
  end


  # -------------------------------------------------------------
  # Gets the username (without the domain) of the e-mail address, if possible.
  def email_without_domain
    if email =~ /(^[^@]+)@/
      $1
    else
      email
    end
  end


  # -------------------------------------------------------------
  def avatar_url(options = {})
    self.avatar.blank? ? gravatar_url(options) : self.avatar
  end


  # -------------------------------------------------------------
  def is_enrolled?(course_offering)
    course_offering && course_offerings.include?(course_offering)
  end


  # -------------------------------------------------------------
  def manages?(course_offering)
    role_for_course_offering(course_offering).andand.can_manage_course?
  end


  # -------------------------------------------------------------
  def teaches?(course_offering)
    role_for_course_offering(course_offering).andand.is_instructor?
  end


  # -------------------------------------------------------------
  def grades?(course_offering)
    role_for_course_offering(course_offering).andand.can_grade_submissions?
  end


  # -------------------------------------------------------------
  def is_staff?(course_offering)
    role_for_course_offering(course_offering).andand.is_staff?
  end


  # -------------------------------------------------------------
  def role_for_course_offering(course_offering)
    course_offering && course_enrollments.
      where(course_offering: course_offering).first.andand.course_role
  end


  # -------------------------------------------------------------
  # Omni auth for Facebook and Google Users
  def self.from_omniauth(auth, guest = nil)
    user = nil
    identity = Identity.where(uid: auth.uid, provider: auth.provider).first
    if identity
      user = identity.user
    else
      if auth.provider == :cas
        auth.info.email = auth.uid + '@vt.edu'
      end
      if auth.info.email
        user = User.where(email: auth.info.email).first
        if !user
          user = User.create(
            first_name: auth.info.first_name,
            last_name: auth.info.last_name,
            email: auth.info.email,
            confirmed_at: DateTime.now,
            password: Devise.friendly_token[0, 20])
        end
      end
      if user
        user.identities.create(uid: auth.uid, provider: auth.provider)
      end
    end

    # Update any blank fields from provider's info, if available
    if user
      user.first_name ||= auth.info.first_name
      user.last_name ||= auth.info.last_name
      user.email ||= auth.info.email
      user.avatar ||= auth.info.image
      user.remember_created_at = DateTime.now
      if !user.confirmed_at
        user.confirmed_at = user.remember_created_at
      end
      if user.changed?
        user.save
      end
    end
    return user
  end


  # -------------------------------------------------------------
  def normalize_friendly_id(value)
    value.split('@').map{ |x| CGI.escape x }.join('@')
  end


  #~ Private instance methods .................................................
  private

    # -------------------------------------------------------------
    # Sets the first user's role as administrator and subsequent users
    # as student (note: be sure to run rake db:seed to create these roles)
    def set_default_role
      if User.count == 0
        self.global_role = GlobalRole.administrator
      elsif self.global_role.nil?
        self.global_role = GlobalRole.regular_user
      end
    end


    # -------------------------------------------------------------
    # Overrides the built-in password required method to allow for users
    # to be updated without errors
    # taken from: http://www.chicagoinformatics.com/index.php/2012/09/
    # user-administration-for-devise/
    def password_required?
      # only set when creating a new user through LTI
      return false if skip_password_validation

      (!password.blank? && !password_confirmation.blank?) || new_record?
    end


    # -------------------------------------------------------------
    def email_or_id
      email || id
    end


    # -------------------------------------------------------------
    def should_generate_new_friendly_id?
      slug.blank? || email_changed?
    end

end
