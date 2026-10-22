# frozen_string_literal: true

class Team < ApplicationRecord

  # Core associations
  has_many :signed_up_teams, dependent: :destroy
  has_many :project_topics, through: :signed_up_teams
  has_many :teams_users, dependent: :destroy
  has_many :teams_participants, dependent: :destroy
  has_many :users, through: :teams_participants
  has_many :participants, through: :teams_participants
  has_many :join_team_requests, dependent: :destroy

  # The team is either an AssignmentTeam or a CourseTeam
  belongs_to :assignment, class_name: 'Assignment', foreign_key: 'parent_id', optional: true
  belongs_to :course, class_name: 'Course', foreign_key: 'parent_id', optional: true
  belongs_to :user, optional: true # Team creator

  attr_accessor :max_participants
  validates :parent_id, presence: true
  validates :type, presence: true, inclusion: { in: %w[AssignmentTeam CourseTeam MentoredTeam], message: "must be 'Assignment' or 'Course' or 'Mentor'" }

  after_update :release_topics_if_empty

  def has_member?(user)
    participants.exists?(user_id: user.id)
  end
  
  # Returns the current number of team members
  def team_size
    users.count
  end
  
  # Course teams have no configured limit; mentored teams inherit assignment limits.
  def max_size
    return nil unless is_a?(AssignmentTeam)

    assignment&.max_team_size
  end
  
  def full?
    # Use the same limit for reporting and admission; nil means uncapped.
    limit = max_size
    return false if limit.nil?

    participants.count >= limit
  end

  # Checks if the given participant is already on any team for the associated assignment or course.
  def participant_on_team?(participant)
    # pick the correct “scope” (assignment or course) based on this team’s class
    scope =
      if is_a?(AssignmentTeam)
        assignment
      elsif is_a?(CourseTeam)
        course
      end

    return false unless scope

    # “scope.teams” includes this team itself plus any sibling teams;
    # check whether any of those teams already has this participant
    scope.teams.any? { |team| team.participants.include?(participant) }
  end

  # Adds participant in the team
  def add_member(participant_or_user)
    context = membership_context
    return { success: false, error: "Team must belong to Assignment or Course" } unless context

    scope, participant_type, label = context
    return { success: false, error: "Team parent is missing" } unless scope

    unless participant_or_user.is_a?(User) || participant_or_user.is_a?(participant_type)
      return { success: false, error: "Expected a User or #{participant_type.name}" }
    end

    # Direct participant input must satisfy the same parent scope as a User lookup.
    participant = resolve_participant(participant_or_user, participant_type, scope)
    unless participant&.persisted? && participant.parent_id == scope.id
      return { success: false, error: "User is not a participant in this #{label}" }
    end

    # Sibling membership is checked by eligibility, not here: transfers add before removing.
    return { success: false, error: "Participant already on the team" } if participants.exists?(id: participant.id)
    return { success: false, error: "Unable to add participant: team is at full capacity." } if full?

    team_participant = TeamsParticipant.create(
      participant_id: participant.id,
      team_id: id,
      user_id: participant.user_id
    )

    if team_participant.persisted?
      { success: true }
    else
      { success: false, error: team_participant.errors.full_messages.join(', ') }
    end
  # Return database failures to callers while allowing programming errors to surface.
  rescue ActiveRecord::ActiveRecordError => e
    { success: false, error: e.message }
  end

  # Removes a participant from this team.
  # - Delete the TeamsParticipant join record
  # - if the participant sent any invitations while being on the team, they all need to be retracted
  # - If the team has no remaining members, destroy the team itself
  def remove_member(participant)
    # retract all the invitations the participant sent (if any) while being on the this team
    participant.retract_sent_invitations

    # Participant#team reads this join; this method no longer maintains legacy team_id.
    tp = TeamsParticipant.find_by(team_id: id, participant_id: participant.id)
    tp&.destroy
    
    # If no participants remain after removal, delete the team
    destroy if participants.empty?
  end

  # Determines whether a given participant is eligible to join the team.
  def can_participant_join_team?(participant)
    context = membership_context
    return { success: false, error: "Team must belong to Assignment or Course" } unless context

    scope, participant_type, label = context
    return { success: false, error: "Team parent is missing" } unless scope

    # Check if the user is already part of any team for this assignment or course
    if participant_on_team?(participant)
      return { success: false, error: "This user is already assigned to a team for this #{label}" }
    end

    # Check if the user is a registered participant for this assignment or course
    registered = participant_type.find_by(
      user_id: participant.user_id,
      parent_id: scope.id
    )

    unless registered
      return { success: false, error: "#{participant.user.name} is not a participant in this #{label}" }
    end

    # All checks passed; participant is eligible to join the team
    { success: true }

  end

  private

  # Keep admission and eligibility aligned; MentoredTeam inherits AssignmentTeam.
  def membership_context
    if is_a?(AssignmentTeam)
      [assignment, AssignmentParticipant, "assignment"]
    elsif is_a?(CourseTeam)
      [course, CourseParticipant, "course"]
    end
  end

  def resolve_participant(participant_or_user, participant_type, scope)
    if participant_or_user.is_a?(User)
      # A user can have registrations under multiple parents; select this team's context.
      participant_type.find_by(user_id: participant_or_user.id, parent_id: scope.id)
    else
      participant_or_user
    end
  end

  def release_topics_if_empty
    return unless participants.empty?
    project_topics.each { |topic| topic.drop_team(self) }
  end
end
