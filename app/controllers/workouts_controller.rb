require 'json'
require 'date'

class WorkoutsController < ApplicationController
  include ArrayHelper
  before_action :set_workout, only: [:show, :update, :destroy]
  after_action :allow_iframe, only: [:new, :new_create, :edit, :embed]
  respond_to :html, :js

  #~ Action methods ...........................................................

  # -------------------------------------------------------------
  # GET /workouts
  def index
    # if cannot? :index, Workout
    #   redirect_to root_path,
    #     notice: 'Unauthorized to view all workouts' and return
    # end
    @workouts = Workout.where(is_public: true)
    @gym = []
  end


  # -------------------------------------------------------------
  # GET /workouts/download.json
  def download
    if cannot? :index, Workout
      redirect_to root_path,
        notice: 'Unauthorized to view all workouts' and return
    end
    @workouts = Workout.accessible_by(current_ability)
    respond_to do |format|
      format.json do
        render text:
          WorkoutRepresenter.for_collection.new(@workouts).to_hash.to_json
      end
      format.yml do
        render text:
          WorkoutRepresenter.for_collection.new(@workouts).to_hash.to_yaml
      end
    end
  end


  # -------------------------------------------------------------
  # GET /workouts/1
  def show
    if can? :read, @workout
      @exs = @workout.exercises
    else
      redirect_to gym_path, flash: {
        error: 'You do not have permission to access that non-public workout.
          Have a look at these popular workouts instead.'
      }
    end
  end

  def embed
    workouts = Workout.where('lower(name) = ? and is_public = true', params[:resource_name].downcase)
    @workout = workouts.first
    if @workout
      redirect_to practice_workout_path(id: @workout.id, lti_launch: true) and return
    else
      @message = 'Sorry, there are no public workouts with that name.'
      render 'lti/error' and return
    end
  end

  def review
    @exs = @workout.exercises
  end
  # -------------------------------------------------------------
  # GET /gym
  def gym
    @gym = Workout.where(is_public: true).order('created_at DESC').
      limit(12)
    # render layout: 'two_columns'
  end


  # -------------------------------------------------------------
  # GET /workouts/new
  def new
    if cannot? :new, Workout
      redirect_to root_path,
        notice: 'Unauthorized to create new workout' and return
    end
    @lti_launch = params[:lti_launch]
    @workout = Workout.new
    @course = Course.find params[:course_id]
    @term = Term.find params[:term_id]
    @organization = Organization.find params[:organization_id]
    @course_offerings = current_user.managed_course_offerings @course, @term

    if params[:notice]
      flash.now[:notice] = params[:notice]
    end

    if @lti_launch
      render layout: 'one_column'
    else
      render layout: 'two_columns'
    end
  end

  # -------------------------------------------------------------
  # GET /gym/workouts/existing_or_new
  def new_or_existing
    if cannot? :new, Workout
      flash.now[:notice] = 'You are unauthorized to create new workouts. Choose from existing workouts instead.'
    end

    @lti_launch = params[:lti_launch]
    @course = Course.find params[:course_id]
    @term = Term.find params[:term_id]
    @organization = Organization.find params[:organization_id]

    @workout_offerings = @course.course_offerings.joins(:workout_offerings, :term)
      .order('terms.ends_on DESC')
      .flat_map(&:workout_offerings)

    # workouts_with_term is of the form [[CourseOffering, WorkoutOffering], [CourseOffering, WorkoutOffering], [CourseOffering, WorkoutOffering]]
    # we will convert it into a Hash where each key is a term, and each value is an array of Workouts
    workouts_with_term = @workout_offerings.map { |wo|
      [wo.course_offering.term, wo]
    }.group_by(&:first).map{ |k, a| [k, a.map(&:last)] }

    @default_results = array_to_hash(workouts_with_term)

    # make sure each term shows unique Workouts
    @default_results.each do |term, workout_offerings|
      @default_results[term] = workout_offerings.uniq{ |wo| wo.workout }
    end
    render layout: 'one_column'
  end

  # -------------------------------------------------------------
  # GET /workouts/new_with_search/:searchkey
  def new_with_search
    @workout = Workout.new
    @exers = Exercise.find_by_sql(
      "SELECT * FROM exercises WHERE name LIKE '%#{params[:searchkey]}%'")
  end

  # -------------------------------------------------------------
  # POST /gym/workouts/search
  def search
    terms = escape_javascript(params[:search])
    terms = terms.split(terms.include?(' ') ? /\s*,\s*/ : nil)
    course = params[:course] ? Course.find(params[:course]) : nil
    searching_offerings = params[:offerings]
    @workouts = Workout.search terms, current_user, course, searching_offerings

    if @workouts.blank?
      @msg = 'Your search did not match any workouts. Try these instead...'
      @workouts = Workout.search nil, current_user, course, searching_offerings
    end

    if @workouts.blank?
      @msg = 'No public workouts exist yet. Please wait for contributors to add more.'
    end

    respond_to do |format|
      format.html
      format.js
    end
  end

  # -------------------------------------------------------------
  # GET /workouts/1/edit
  def edit
    @workout_offering = WorkoutOffering.find(params[:workout_offering_id])
    @workout = @workout_offering.workout

    if cannot? :edit, @workout
      redirect_to root_path, notice: 'You are not authorized to edit this workout.' and return
    end

    @course = Course.find(params[:course_id])
    @term = Term.find(params[:term_id])
    @can_update = can? :edit, @workout
    @time_limit = @workout.workout_offerings.first.andand.time_limit
    @published = @workout.workout_offerings.first.andand.published
    @most_recent = @workout.workout_offerings.first.andand.most_recent
    @policy = @workout.workout_offerings.first.andand.workout_policy
    @organization = Organization.find params[:organization_id]
    @lti_launch = params[:lti_launch]

    @exercises = []
    @workout.exercise_workouts.each do |ex|
      ex_data = {}
      ex_data[:name] = ex.exercise.name
      ex_data[:points] = ex.points
      ex_data[:id] = ex.exercise_id
      ex_data[:exercise_workout_id] = ex.id
      @exercises.push(ex_data)
    end

    @workout_offerings = current_user.managed_workout_offerings_in_term(@workout, @course, @term).flatten

    course_offerings = current_user.managed_course_offerings @course, @term
    used_course_offerings = @workout_offerings.flat_map(&:course_offering)
    @unused_course_offerings = course_offerings - used_course_offerings

    @student_extensions = []
    @workout_offerings.each do |workout_offering|
      workout_offering.student_extensions.each do |e|
        ext = {}
        ext[:id] = e.id
        ext[:student_id] = e.user.id
        ext[:student_display] = e.user.display_name
        ext[:course_offering_id] = e.workout_offering.course_offering_id
        ext[:course_offering_display] = e.workout_offering.course_offering.display_name_with_term
        ext[:opening_date] = e.opening_date.andand.to_i
        ext[:soft_deadline] = e.soft_deadline.andand.to_i
        ext[:hard_deadline] = e.hard_deadline.andand.to_i
        ext[:time_limit] = e.time_limit
        @student_extensions.push(ext)
      end
    end

    if @lti_launch
      render layout: 'one_column'
    else
      render layout: 'two_columns'
    end
  end

  def clone
    @workout = Workout.find params[:workout_id]
    @course = Course.find params[:course_id]
    @term = Term.find(params[:term_id])
    @can_update = can? :edit, @workout
    @time_limit = @workout.workout_offerings.first.andand.time_limit
    @organization = Organization.find params[:organization_id]
    @lti_launch = params[:lti_launch]

    @exercises = []
    @workout.exercise_workouts.each do |ex|
      ex_data = {}
      ex_data[:name] = ex.exercise.name
      ex_data[:points] = ex.points
      ex_data[:id] = ex.exercise_id
      ex_data[:exercise_workout_id] = ex.id
      @exercises.push(ex_data)
    end

    @course_offerings = current_user.managed_course_offerings @course, @term
    @unused_course_offerings = nil

    if @lti_launch
      render layout: 'one_column'
    else
      render layout: 'two_columns'
    end
  end

  def create
    @workout = Workout.new
    @workout.creator_id = current_user.id
    @lti_launch = params[:lti_launch]
    workout_offering_id = create_or_update

    if @workout.save
      if @lti_launch
        lti_params = session[:lti_params]
        url = url_for(organization_workout_offering_path(
            organization_id: params[:organization_id],
            course_id: params[:course_id],
            term_id: params[:term_id],
            id: workout_offering_id,
            lti_launch: true
          )
        )
      else
        if workout_offering_id.nil?
          url = url_for(workout_path(id: @workout.id))
        else
          url = url_for(organization_workout_offering_path(
              organization_id: params[:organization_id],
              term_id: params[:term_id],
              course_id: params[:course_id],
              id: workout_offering_id
            )
          )
        end
      end
    else
      err_string = 'There was a problem while creating the workout.'
      url = url_for organization_new_workout_path(
        organization_id: params[:organization_id],
        term_id: params[:term_id],
        course_id: params[:course_id],
        notice: err_string
      )
    end

    respond_to do |format|
      format.json { render json: { url: url } }
    end
  end

  def find_offering
    @user = User.find(params[:user_id])
    @term = Term.find(params[:term_id])
    @course = Course.find(params[:course_id])

    # Find all workouts with the specified name, then find the relevant
    # set of workout_offerings
    @workouts = Workout.where name: params[workout_name]
    workout_offerings = []
    @workouts.each do |w|
      workout_offerings << w.workout_offerings.joins(:course_offering).
        where(course_offering:
          { term: @term, course: @course }
        )
    end
    workout_offerings = workout_offerings.flatten.uniq
  end

  def upload_yaml

  end

  def yaml_create
    @yaml_wkts = YAML.load_file(params[:form].fetch(:yamlfile).path)
    @yaml_wkts.each do |workout|
      wkt = workout['workout']
      @wkt = Workout.new
      @wkt.name = wkt['name']
      @wkt.scrambled = wkt['scrambled']
      @wkt.description = wkt['description']
      @wkt.save
      wkt['tags'].split(",").each do |t|
        Tag.tag_this_with(@wkt,t,Tag.skill)
      end
      wkt['exercises'].andand.each_with_index do |exer,i|
        if Exercise.find(exer['exid'][1..-1].to_i)
          ex_wkt = ExerciseWorkout.new
          ex_wkt.exercise_id = exer['exid'][1..-1].to_i
          ex_wkt.workout_id = @wkt.id
          ex_wkt.points = exer['points']
          ex_wkt.order = i + 1
          ex_wkt.save
        else
          puts "Exercise not found"
        end
      end
      wkt['offerings'].andand.each_with_index do |off, i|
        matching_course = Course.find_by(number: off['course']['number'],organization: Organization.find_by(abbreviation: off['course']['organization']['abbreviation']))
        if matching_course
          wkt_off = WorkoutOffering.new
          wkt_off.opening_date = off['opening_date']
          wkt_off.soft_deadline = off['soft_deadline']
          wkt_off.hard_deadline = off['hard_deadline']
          wkt_off.course_offering_id = matching_course.id
          wkt_off.workout_id = @wkt.id
          wkt_off.save
        else
          puts "No MATCHING COURSE","No MATCHING COURSE"
        end
      end
    end
    redirect_to workouts_path
  end

  # ------Placeholder for any views I want experiment with-------------------------------------------------------
  def dummy
    @workouts = Workout.find(1)
  end

  # -------------------------------------------------------------
  def evaluate
    if session[:current_workout].nil?
      redirect_to root_path, notice: 'Invalid action' and return
    end
    @workout_feedback = session[:workout_feedback].values
    @current_workout = Workout.find(session[:current_workout])
    @user_workout_score = WorkoutScore.find_by!(
      user_id: current_user.id, workout_id: session[:current_workout]).score
    @max_workout_score = @current_workout.returnTotalWorkoutPoints
    session[:current_workout] = nil
    session[:workout_feedback] = nil
    session[:wexes] = nil
    session[:remaining_wexes] = nil
    render layout: 'two_columns'
  end


  # -------------------------------------------------------------
  # PATCH/PUT /workouts/1
  # def update
  #   if cannot? :update, @workout
  #     redirect_to root_path,
  #       notice: 'Unauthorized to update workout' and return
  #   end
  #   if @workout.update(workout_params)
  #     redirect_to @workout, notice: 'Workout was successfully updated.'
  #   else
  #     render action: 'edit'
  #   end
  # end

  def update
    if cannot? :update, @workout
      redirect_to root_path,
        notice: 'Unauthorized to update workout' and return
    end

    workout_offering_id = create_or_update
    @workout.save!
    if workout_offering_id.nil?
      url = url_for(workout_path(id: @workout.id))
    else
      url = url_for(organization_workout_offering_path(
          organization_id: params[:organization_id],
          term_id: params[:term_id],
          course_id: params[:course_id],
          id: workout_offering_id
        )
      )
    end

    respond_to do |format|
      format.json { render json: { url: url } }
    end
  end


  # -------------------------------------------------------------
  # DELETE /workouts/1
  def destroy
    if cannot? :destroy, @workout
      redirect_to root_path,
        notice: 'Unauthorized to destroy workout' and return
    end
    @workout.destroy
    redirect_to workouts_url, notice: 'Workout was successfully destroyed.'
  end


  # -------------------------------------------------------------
  def practice
    @workout = Workout.find_by(id: params[:id])
    authorize! :practice, @workout
    if @workout
      session[:current_workout] = @workout.id
      if current_user
        @workout_score = @workout.score_for(current_user)
        if @workout_score.nil?
          @workout_score = WorkoutScore.new(
            score: 0,
            exercises_completed: 0,
            exercises_remaining: @workout.exercises.length,
            user: current_user,
            workout: @workout)
          @workout_score.save!
        end
        current_user.current_workout_score = @workout_score
        current_user.save!
        if @workout_score.andand.closed? &&
          @workout_score.andand.workout_offering.andand.workout_policy.
          andand.no_review_before_close &&
          !@workout_score.andand.workout_offering.andand.shutdown?
          redirect_to workout_path(@workout),
            notice: "The time limit has passed for this workout." and return
        end
      end
      ex1 = @workout.next_exercise(nil, current_user, @workout_score)
      redirect_to exercise_practice_path(id: ex1.id, workout_id: @workout.id, lti_launch: params[:lti_launch])
    else
      redirect_to workouts, notice: 'Workout not found' and return
    end
  end


  #~ Private instance methods .................................................
  private

    # -------------------------------------------------------------
    # Use callbacks to share common setup or constraints between actions.
    def set_workout
      @workout = Workout.find(params[:id])
      @xp = 30
      @xptogo = 60
      @remain = 10
    end

    def create_or_update
      @workout.name = params[:name]
      @workout.description = params[:description]
      @workout.is_public = params[:is_public]

      common = {}   # params that are common among all offerings of this workout
      common[:workout_policy] = WorkoutPolicy.find_by id: params[:policy_id]
      common[:time_limit] = params[:time_limit]
      common[:published] = params[:published]
      common[:most_recent] = params[:most_recent]

      removed_exercises = JSON.parse params[:removed_exercises]
      removed_exercises.each do |exercise_workout_id|
        @workout.exercise_workouts.destroy exercise_workout_id
      end

      exercises = JSON.parse params[:exercises]
      exercises.each_with_index do |ex, index|
        exercise = Exercise.find ex['id']
        exercise_workout = ExerciseWorkout.find_by workout: @workout, exercise: exercise
        if exercise_workout.blank?
          exercise_workout = ExerciseWorkout.new workout: @workout, exercise: exercise
        end
        exercise_workout.set_list_position index
        exercise_workout.points = ex['points']
        exercise_workout.save!
      end

      removed_extensions = JSON.parse params[:removed_extensions]
      removed_extensions.each do |extension_id|
        StudentExtension.destroy extension_id
      end

      removed_offerings = JSON.parse params[:removed_offerings]
      removed_offerings.each do |workout_offering_id|
        @workout.workout_offerings.destroy workout_offering_id
      end

      course_offerings = JSON.parse params[:course_offerings]
      workout_offerings = @workout.add_workout_offerings(course_offerings, common)
      return workout_offerings.first
    end

    # -------------------------------------------------------------
    # Only allow a trusted parameter "white list" through.
    def workout_params
      params.require(:workout).permit(:name, :scrambled, :exercise_ids,
        :description, :target_group, :points_multiplier, :opening_date, :exercise_workout,
        :exercise_workouts_attributes, :workout_offerings_attributes,
        :soft_deadline, :hard_deadline)
    end

end
