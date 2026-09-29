# frozen_string_literal: true

require 'rails_helper'
require 'securerandom'

# Independently derived from production code; existing behavioral tests were not consulted.
# Example IDs map to the approved plan. Q examples characterize questionable current behavior.
# Records are created directly without using existing factories or fixtures.
RSpec.describe Team, type: :model do
  def unique_name(prefix)
    "#{prefix}_#{SecureRandom.hex(8)}"
  end

  def make_user
    @study_role ||= Role.create!(name: unique_name('StudyRole'))
    User.create!(name: unique_name('study'), full_name: 'Study User',
                 email: "#{unique_name('study')}@example.org",
                 password: 'study-password', password_confirmation: 'study-password',
                 role: @study_role)
  end

  def make_parent(kind = :assignment, max_team_size: 3)
    if kind == :course
      institution = Institution.create!(name: unique_name('StudyInstitution'))
      Course.create!(name: unique_name('course'), directory_path: 'study-course',
                     instructor: make_user, institution: institution)
    else
      Assignment.create!(name: unique_name('assignment'), instructor: make_user,
                         max_team_size: max_team_size)
    end
  end

  def make_team(kind = :assignment, parent: nil, **attributes)
    parent ||= make_parent(kind == :course ? :course : :assignment)
    klass = { assignment: AssignmentTeam, course: CourseTeam, mentored: MentoredTeam }.fetch(kind)
    klass.create!({ name: unique_name('team'), parent_id: parent.id }.merge(attributes))
  end

  def make_participant(parent:, user: nil, kind: nil, **attributes)
    user ||= make_user
    kind ||= parent.is_a?(Course) ? :course : :assignment
    klass = kind == :course ? CourseParticipant : AssignmentParticipant
    klass.create!({ user: user, parent_id: parent.id, handle: unique_name('handle') }.merge(attributes))
  end

  def link_member(team, participant)
    TeamsParticipant.create!(team: team, participant: participant, user: participant.user)
  end

  def make_member(team)
    parent = team.is_a?(CourseTeam) ? team.course : team.assignment
    participant = make_participant(parent: parent)
    link_member(team, participant)
    participant
  end

  def make_topic(assignment, max_choosers: 1)
    ProjectTopic.create!(assignment: assignment, topic_name: unique_name('topic'),
                         max_choosers: max_choosers)
  end

  def sign_up(team, topic, waitlisted: false, **attributes)
    SignedUpTeam.create!({ team: team, project_topic: topic, is_waitlisted: waitlisted }.merge(attributes))
  end

  describe "validations and associations" do
    # Verifies that the supported subtype is valid with its parent.
    it "V1-assignment accepts a valid assignment team" do
      team = make_team(:assignment)
      expect(team).to be_valid
      expect(Team.find(team.id)).to be_a(AssignmentTeam)
      expect(team.type).to eq('AssignmentTeam')
    end

    # Verifies that the supported subtype is valid with its parent.
    it "V1-course accepts a valid course team" do
      team = make_team(:course)
      expect(team).to be_valid
      expect(Team.find(team.id)).to be_a(CourseTeam)
      expect(team.type).to eq('CourseTeam')
    end

    # Verifies that the supported subtype is valid with its parent.
    it "V1-mentored accepts a valid mentored team" do
      team = make_team(:mentored)
      expect(team).to be_valid
      expect(Team.find(team.id)).to be_a(MentoredTeam)
      expect(team.type).to eq('MentoredTeam')
    end

    # Verifies the parent identifier presence validation.
    it "V2 requires a parent identifier" do
      team = AssignmentTeam.new(name: 'orphan')
      team.validate
      expect(team.errors.of_kind?(:parent_id, :blank)).to be(true)
    end

    # Verifies type validation without triggering STI construction.
    it "V3-blank rejects a blank type" do
      team = Team.new(name: 'type-check', parent_id: 123)
      team.type = nil
      team.validate
      expect(team.errors.of_kind?(:type, :blank)).to be(true)
    end

    # Verifies type validation without triggering STI construction.
    it "V3-unsupported rejects a unsupported type" do
      team = Team.new(name: 'type-check', parent_id: 123)
      team.type = 'UnsupportedTeam'
      team.validate
      expect(team.errors.of_kind?(:type, :inclusion)).to be(true)
    end

    # Verifies the optional creator relationship.
    it "V4 allows an absent creator" do
      team = make_team
      expect(team).to be_valid
      expect(team.user).to be_nil
    end

    # Verifies that parent_id resolves the appropriate parent.
    it "V5-assignment resolves its assignment parent" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      expect(team.reload.assignment).to eq(parent)
    end

    # Verifies that parent_id resolves the appropriate parent.
    it "V5-course resolves its course parent" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      expect(team.reload.course).to eq(parent)
    end

    # Verifies the real through-association records.
    it "V6 exposes membership and topic associations" do
      team = make_team
      participant = make_member(team)
      topic = make_topic(team.assignment)
      sign_up(team, topic)
      expect(team.participants).to contain_exactly(participant)
      expect(team.users).to contain_exactly(participant.user)
      expect(team.project_topics).to contain_exactly(topic)
    end

    # Verifies dependent destruction without deleting shared entities.
    it "V7 destroys dependent joins while preserving related entities" do
      team = make_team
      participant = make_member(team)
      user = participant.user
      topic = make_topic(team.assignment)
      membership = team.teams_participants.sole
      legacy = TeamsUser.create!(team: team, user: user)
      signup = sign_up(team, topic)
      request = JoinTeamRequest.create!(team: team, participant: participant, reply_status: 'PENDING')
      team.destroy!
      expect(Team.exists?(team.id)).to be(false)
      [membership, legacy, signup, request].each do |record|
        expect(record.class.exists?(record.id)).to be(false)
      end
      expect(User.exists?(user.id)).to be(true)
      expect(Participant.exists?(participant.id)).to be(true)
      expect(ProjectTopic.exists?(topic.id)).to be(true)
      expect(Assignment.exists?(team.parent_id)).to be(true)
    end
  end

  describe "#has_member? and #team_size" do
    # Verifies both matching and nonmatching user membership.
    it "M1 recognizes only a linked participant user" do
      team = make_team
      member = make_member(team)
      expect(team.has_member?(member.user)).to be(true)
      expect(team.has_member?(make_user)).to be(false)
    end

    # Verifies that legacy joins do not count as current memberships.
    it "M2 ignores legacy user joins for membership and size" do
      team = make_team
      user = make_user
      TeamsUser.create!(team: team, user: user)
      expect(team.has_member?(user)).to be(false)
      expect(team.team_size).to eq(0)
    end

    # Verifies the member count before and after persisted joins.
    it "M3 counts empty and populated teams" do
      team = make_team
      expect(team.team_size).to eq(0)
      2.times { make_member(team) }
      expect(team.team_size).to eq(2)
    end

    # Documents the unguarded user ID access.
    it "M4 raises for a nil user" do
      expect { make_team.has_member?(nil) }.to raise_error(NoMethodError)
    end
  end

  describe "#max_size and #full?" do
    # Verifies inherited assignment capacity lookup.
    it "C1-assignment returns the assignment limit for assignment teams" do
      parent = make_parent(max_team_size: 4)
      expect(make_team(:assignment, parent: parent).max_size).to eq(4)
    end

    # Verifies inherited assignment capacity lookup.
    it "C1-mentored returns the assignment limit for mentored teams" do
      parent = make_parent(max_team_size: 4)
      expect(make_team(:mentored, parent: parent).max_size).to eq(4)
    end

    # Verifies fallback behavior when assignment capacity is unavailable.
    it "C2-absent-parent treats an absent parent as unbounded" do
      team = AssignmentTeam.new(name: 'orphan')
      expect(team.max_size).to be_nil
      expect(team.full?).to be(false)
    end

    # Verifies fallback behavior when assignment capacity is unavailable.
    it "C2-nil-limit treats an nil limit as unbounded" do
      team = make_team(parent: make_parent(max_team_size: nil))
      expect(team.max_size).to be_nil
      expect(team.full?).to be(false)
    end

    # Verifies the capacity comparison at this boundary.
    it "C3-1 reports fullness with 1 members and a limit of two" do
      team = make_team(parent: make_parent(max_team_size: 2))
      1.times { make_member(team) }
      expect(team.full?).to be(false)
    end

    # Verifies the capacity comparison at this boundary.
    it "C3-2 reports fullness with 2 members and a limit of two" do
      team = make_team(parent: make_parent(max_team_size: 2))
      2.times { make_member(team) }
      expect(team.full?).to be(true)
    end

    # Verifies the capacity comparison at this boundary.
    it "C3-3 reports fullness with 3 members and a limit of two" do
      team = make_team(parent: make_parent(max_team_size: 2))
      3.times { make_member(team) }
      expect(team.full?).to be(true)
    end

    # Verifies that zero is a configured limit.
    it "C4 treats zero capacity as full" do
      team = make_team(parent: make_parent(max_team_size: 0))
      expect(team.max_size).to eq(0)
      expect(team.full?).to be(true)
    end

    # Verifies the course capacity fallback with actual members.
    it "C5 does not fill a course team" do
      team = make_team(:course)
      2.times { make_member(team) }
      expect(team.full?).to be(false)
    end

    # Verifies safe navigation for a missing course.
    it "C6-course returns no maximum for an absent course" do
      expect(CourseTeam.new(name: 'orphan').max_size).to be_nil
    end

    # Verifies unsupported runtime class fallbacks.
    it "C6-base uses fallback capacity for a base Team" do
      team = Team.new
      expect(team.max_size).to be_nil
      expect(team.full?).to be(false)
    end

    # Verifies that the transient accessor does not override the parent.
    it "C7 ignores max_participants when enforcing assignment capacity" do
      team = make_team(parent: make_parent(max_team_size: 3))
      team.max_participants = 0
      expect(team.max_size).to eq(3)
      expect(team.full?).to be(false)
    end
  end

  describe "#participant_on_team?" do
    # Verifies current-team inclusion in the parent scope.
    it "P1-assignment finds membership on the current assignment team" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      link_member(team, participant)
      expect(team.participant_on_team?(participant)).to be(true)
    end

    # Verifies membership across sibling teams.
    it "P2-assignment finds membership on a sibling assignment team" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      sibling = make_team(:assignment, parent: parent)
      link_member(sibling, participant)
      expect(team.participant_on_team?(participant)).to be(true)
    end

    # Verifies the no-match result across an empty membership set.
    it "P3-assignment rejects an unassigned participant in assignment scope" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      expect(team.participant_on_team?(participant)).to be(false)
    end

    # Verifies the empty parent-team collection.
    it "P3-empty-assignment returns false when the assignment parent has no teams" do
      parent = make_parent(:assignment)
      team = AssignmentTeam.new(parent_id: parent.id, name: 'unsaved')
      participant = make_participant(parent: parent)
      expect(parent.teams).to be_empty
      expect(team.participant_on_team?(participant)).to be(false)
    end

    # Verifies parent isolation in membership lookup.
    it "P4-assignment ignores a membership under another assignment parent" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      other_team = make_team(:assignment)
      link_member(other_team, participant)
      expect(team.participant_on_team?(participant)).to be(false)
    end

    # Verifies the missing-scope early return.
    it "P6-assignment returns false without its assignment parent" do
      team = AssignmentTeam.new
      expect(team.participant_on_team?(Object.new)).to be(false)
    end

    # Verifies current-team inclusion in the parent scope.
    it "P1-course finds membership on the current course team" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      link_member(team, participant)
      expect(team.participant_on_team?(participant)).to be(true)
    end

    # Verifies membership across sibling teams.
    it "P2-course finds membership on a sibling course team" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      sibling = make_team(:course, parent: parent)
      link_member(sibling, participant)
      expect(team.participant_on_team?(participant)).to be(true)
    end

    # Verifies the no-match result across an empty membership set.
    it "P3-course rejects an unassigned participant in course scope" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      expect(team.participant_on_team?(participant)).to be(false)
    end

    # Verifies the empty parent-team collection.
    it "P3-empty-course returns false when the course parent has no teams" do
      parent = make_parent(:course)
      team = CourseTeam.new(parent_id: parent.id, name: 'unsaved')
      participant = make_participant(parent: parent)
      expect(parent.teams).to be_empty
      expect(team.participant_on_team?(participant)).to be(false)
    end

    # Verifies parent isolation in membership lookup.
    it "P4-course ignores a membership under another course parent" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      other_team = make_team(:course)
      link_member(other_team, participant)
      expect(team.participant_on_team?(participant)).to be(false)
    end

    # Verifies the missing-scope early return.
    it "P6-course returns false without its course parent" do
      team = CourseTeam.new
      expect(team.participant_on_team?(Object.new)).to be(false)
    end

    # Verifies STI filtering when assignment and course identifiers overlap.
    it "P5 separates assignment and course scopes with the same parent ID" do
      shared_id = ([Assignment.maximum(:id), Course.maximum(:id)].compact.max || 0) + 1
      assignment = Assignment.create!(id: shared_id, name: unique_name('assignment'),
                                      instructor: make_user, max_team_size: 3)
      course = Course.create!(id: shared_id, name: unique_name('course'), directory_path: 'study',
                              instructor: make_user,
                              institution: Institution.create!(name: unique_name('institution')))
      team = make_team(parent: assignment)
      course_team = make_team(:course, parent: course)
      participant = make_participant(parent: assignment)
      link_member(course_team, participant)
      expect(assignment.teams).not_to include(course_team)
      expect(course.teams).to contain_exactly(course_team)
      expect(team.participant_on_team?(participant)).to be(false)
    end

    # Verifies the unsupported scope fallback.
    it "P6-base returns false for a base Team scope" do
      expect(Team.new.participant_on_team?(Object.new)).to be(false)
    end
  end

  describe "#add_member" do
    # Verifies successful direct-participant membership creation.
    it "A1-assignment adds a assignment participant and persists the correct join" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      result = nil
      expect { result = team.add_member(participant) }.to change(TeamsParticipant, :count).by(1)
      expect(result).to eq(success: true)
      membership = team.teams_participants.sole
      expect(membership.attributes.slice('team_id', 'participant_id', 'user_id')).to eq(
        'team_id' => team.id, 'participant_id' => participant.id, 'user_id' => participant.user_id
      )
    end

    # Verifies subtype and parent filtering when given a User.
    it "A2-assignment resolves a user in the correct assignment scope" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      user = make_user
      make_participant(parent: make_parent(:assignment), user: user)
      make_participant(parent: make_parent(:course), user: user)
      participant = make_participant(parent: parent, user: user)
      expect(team.add_member(user)).to eq(success: true)
      expect(team.teams_participants.pluck(:participant_id, :user_id)).to eq([[participant.id, user.id]])
    end

    # Verifies the missing-registration message and lack of persistence.
    it "A3-assignment rejects an unregistered user in assignment scope" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      user = make_user
      result = nil
      expect { result = team.add_member(user) }.not_to change(TeamsParticipant, :count)
      expect(result).to eq(success: false, error: "#{user.name} is not a participant in this assignment")
    end

    # Verifies successful direct-participant membership creation.
    it "A1-course adds a course participant and persists the correct join" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      result = nil
      expect { result = team.add_member(participant) }.to change(TeamsParticipant, :count).by(1)
      expect(result).to eq(success: true)
      membership = team.teams_participants.sole
      expect(membership.attributes.slice('team_id', 'participant_id', 'user_id')).to eq(
        'team_id' => team.id, 'participant_id' => participant.id, 'user_id' => participant.user_id
      )
    end

    # Verifies subtype and parent filtering when given a User.
    it "A2-course resolves a user in the correct course scope" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      user = make_user
      make_participant(parent: make_parent(:course), user: user)
      make_participant(parent: make_parent(:assignment), user: user)
      participant = make_participant(parent: parent, user: user)
      expect(team.add_member(user)).to eq(success: true)
      expect(team.teams_participants.pluck(:participant_id, :user_id)).to eq([[participant.id, user.id]])
    end

    # Verifies the missing-registration message and lack of persistence.
    it "A3-course rejects an unregistered user in course scope" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      user = make_user
      result = nil
      expect { result = team.add_member(user) }.not_to change(TeamsParticipant, :count)
      expect(result).to eq(success: false, error: "#{user.name} is not a participant in this course")
    end

    # Verifies duplicate rejection without a second membership.
    it "A4-space rejects an existing member when space remains" do
      team = make_team(parent: make_parent(max_team_size: 3))
      participant = make_member(team)
      result = nil
      expect { result = team.add_member(participant) }.not_to change(TeamsParticipant, :count)
      expect(result).to eq(success: false, error: 'Participant already on the team')
    end

    # Verifies duplicate rejection without a second membership.
    it "A4-full rejects an existing member before capacity" do
      team = make_team(parent: make_parent(max_team_size: 1))
      participant = make_member(team)
      result = nil
      expect { result = team.add_member(participant) }.not_to change(TeamsParticipant, :count)
      expect(result).to eq(success: false, error: 'Participant already on the team')
    end

    # Verifies capacity rejection before persistence.
    it "A5 rejects a new participant at full capacity" do
      team = make_team(parent: make_parent(max_team_size: 1))
      make_member(team)
      participant = make_participant(parent: team.assignment)
      result = nil
      expect { result = team.add_member(participant) }.not_to change(TeamsParticipant, :count)
      expect(result).to eq(success: false, error: 'Unable to add participant: team is at full capacity.')
    end

    # Verifies the failed-persistence response without fabricating a successful join.
    it "A6 returns joined validation messages when the join is not persisted" do
      team = make_team
      participant = make_participant(parent: team.assignment)
      failed_join = TeamsParticipant.new
      failed_join.errors.add(:base, 'First membership failure')
      failed_join.errors.add(:base, 'Second membership failure')
      allow(TeamsParticipant).to receive(:create).with(
        participant_id: participant.id, team_id: team.id, user_id: participant.user_id
      ).and_return(failed_join)
      result = nil
      expect { result = team.add_member(participant) }.not_to change(TeamsParticipant, :count)
      expect(result).to eq(success: false, error: 'First membership failure, Second membership failure')
    end

    # Verifies the StandardError rescue at membership creation.
    it "A7 converts a dependency exception into a failure hash" do
      team = make_team
      participant = make_participant(parent: team.assignment)
      allow(TeamsParticipant).to receive(:create).and_raise(StandardError, 'membership storage failed')
      expect(team.add_member(participant)).to eq(success: false, error: 'membership storage failed')
    end

    # Verifies the unsupported-input branch with a usable name.
    it "A8-named rejects an unsupported named object" do
      team = make_team
      input = Struct.new(:name).new('Visitor')
      expect(team.add_member(input)).to eq(success: false, error: 'Visitor is not a participant in this assignment')
    end

    # Verifies that the missing name access is rescued.
    it "A8-nil rescues nil input failure" do
      team = make_team
      result = nil
      expect { result = team.add_member(nil) }.not_to change(TeamsParticipant, :count)
      expect(result).to include(success: false, error: a_kind_of(String))
      expect(result[:error]).not_to be_empty
    end
  end

  describe "#remove_member" do
    # Verifies targeted removal without deleting other members.
    it "R1 removes one member while preserving the populated team" do
      team = make_team
      removed = make_member(team)
      remaining = make_member(team)
      team.remove_member(removed)
      expect(team.reload.participants).to contain_exactly(remaining)
      expect(Participant.exists?(removed.id)).to be(true)
      expect(Participant.exists?(remaining.id)).to be(true)
    end

    # Verifies empty-team destruction after the final membership is removed.
    it "R2 destroys the team when its last member leaves" do
      team = make_team
      participant = make_member(team)
      team.remove_member(participant)
      expect(Team.exists?(team.id)).to be(false)
      expect(TeamsParticipant.exists?(team_id: team.id)).to be(false)
      expect(Participant.exists?(participant.id)).to be(true)
    end

    # Verifies clearing the stored team_id when its getter matches the team.
    it "R3-match clears a course participant's matching legacy team reference" do
      team = make_team(:course)
      participant = make_member(team)
      make_member(team)
      participant.update!(team_id: team.id)
      team.remove_member(participant)
      expect(participant.reload[:team_id]).to be_nil
      expect(team.reload.participants).not_to include(participant)
    end

    # Verifies the nonmatching legacy-reference branch.
    it "R3-other preserves a course participant's reference to another team" do
      team = make_team(:course)
      other_team = make_team(:course, parent: team.course)
      participant = make_member(team)
      make_member(team)
      participant.update!(team_id: other_team.id)
      team.remove_member(participant)
      expect(participant.reload[:team_id]).to eq(other_team.id)
    end

    # Verifies the absent-join path with remaining members.
    it "R4 preserves a populated team when removing a nonmember" do
      team = make_team
      member = make_member(team)
      nonmember = make_participant(parent: team.assignment)
      team.remove_member(nonmember)
      expect(team.reload.participants).to contain_exactly(member)
      expect(Participant.exists?(nonmember.id)).to be(true)
    end

    # Documents the unconditional empty-team check.
    it "R5 destroys an empty team even when the participant was not a member" do
      team = make_team
      participant = make_participant(parent: team.assignment)
      team.remove_member(participant)
      expect(Team.exists?(team.id)).to be(false)
      expect(Participant.exists?(participant.id)).to be(true)
    end

    # Verifies the invitation boundary while membership still exists.
    it "R6 retracts invitations before deleting the membership" do
      team = make_team
      participant = make_member(team)
      expect(participant).to receive(:retract_sent_invitations).once do
        expect(TeamsParticipant.exists?(team_id: team.id, participant_id: participant.id)).to be(true)
      end
      team.remove_member(participant)
      expect(TeamsParticipant.exists?(team_id: team.id, participant_id: participant.id)).to be(false)
    end

    # Verifies that retraction failure stops removal.
    it "R7 propagates invitation errors before changing membership" do
      team = make_team
      participant = make_member(team)
      allow(participant).to receive(:retract_sent_invitations).and_raise(StandardError, 'retraction failed')
      expect { team.remove_member(participant) }.to raise_error(StandardError, 'retraction failed')
      expect(Team.exists?(team.id)).to be(true)
      expect(TeamsParticipant.exists?(team_id: team.id, participant_id: participant.id)).to be(true)
    end

    # Documents partial state when the later update! raises.
    it "R8 leaves the membership removed when participant updating fails" do
      team = make_team(:course)
      participant = make_member(team)
      participant.update!(team_id: team.id)
      allow(participant).to receive(:update!).with(team_id: nil).and_raise(ActiveRecord::RecordInvalid.new(participant))
      expect { team.remove_member(participant) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(TeamsParticipant.exists?(team_id: team.id, participant_id: participant.id)).to be(false)
      expect(Team.exists?(team.id)).to be(true)
      expect(participant.reload[:team_id]).to eq(team.id)
    end
  end

  describe "#can_participant_join_team?" do
    # Verifies eligibility when registration exists and no membership conflicts.
    it "E1-assignment accepts an unassigned registered assignment participant" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      expect(team.can_participant_join_team?(participant)).to eq(success: true)
    end

    # Verifies the already-assigned eligibility error.
    it "E2-assignment-current rejects membership on the current assignment team" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      member_team = team
      link_member(member_team, participant)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this assignment'
      )
    end

    # Verifies the already-assigned eligibility error.
    it "E2-assignment-sibling rejects membership on the sibling assignment team" do
      parent = make_parent(:assignment)
      team = make_team(:assignment, parent: parent)
      participant = make_participant(parent: parent)
      member_team = make_team(:assignment, parent: parent)
      link_member(member_team, participant)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this assignment'
      )
    end

    # Verifies the registration query is scoped to this parent.
    it "E3-assignment rejects registration only under another assignment parent" do
      team = make_team(:assignment)
      participant = make_participant(parent: make_parent(:assignment))
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: "#{participant.user.name} is not a participant in this assignment"
      )
    end

    # Verifies rejection order when both conditions fail.
    it "E4-assignment prioritizes membership over registration for assignment eligibility" do
      team = make_team(:assignment)
      sibling = make_team(:assignment, parent: team.assignment)
      participant = make_participant(parent: make_parent(:assignment))
      link_member(sibling, participant)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this assignment'
      )
    end

    # Documents the unguarded scope ID access.
    it "E7-parent-assignment raises for missing assignment scope during registration lookup" do
      team = AssignmentTeam.new
      participant = make_participant(parent: make_parent(:assignment))
      expect { team.can_participant_join_team?(participant) }.to raise_error(NoMethodError)
    end

    # Verifies eligibility when registration exists and no membership conflicts.
    it "E1-course accepts an unassigned registered course participant" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      expect(team.can_participant_join_team?(participant)).to eq(success: true)
    end

    # Verifies the already-assigned eligibility error.
    it "E2-course-current rejects membership on the current course team" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      member_team = team
      link_member(member_team, participant)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this course'
      )
    end

    # Verifies the already-assigned eligibility error.
    it "E2-course-sibling rejects membership on the sibling course team" do
      parent = make_parent(:course)
      team = make_team(:course, parent: parent)
      participant = make_participant(parent: parent)
      member_team = make_team(:course, parent: parent)
      link_member(member_team, participant)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this course'
      )
    end

    # Verifies the registration query is scoped to this parent.
    it "E3-course rejects registration only under another course parent" do
      team = make_team(:course)
      participant = make_participant(parent: make_parent(:course))
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: "#{participant.user.name} is not a participant in this course"
      )
    end

    # Verifies rejection order when both conditions fail.
    it "E4-course prioritizes membership over registration for course eligibility" do
      team = make_team(:course)
      sibling = make_team(:course, parent: team.course)
      participant = make_participant(parent: make_parent(:course))
      link_member(sibling, participant)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this course'
      )
    end

    # Documents the unguarded scope ID access.
    it "E7-parent-course raises for missing course scope during registration lookup" do
      team = CourseTeam.new
      participant = make_participant(parent: make_parent(:course))
      expect { team.can_participant_join_team?(participant) }.to raise_error(NoMethodError)
    end

    # Verifies eligibility does not enforce capacity.
    it "E5 accepts an eligible participant even when capacity is exhausted" do
      team = make_team(parent: make_parent(max_team_size: 1))
      make_member(team)
      participant = make_participant(parent: team.assignment)
      expect(team.full?).to be(true)
      expect(team.can_participant_join_team?(participant)).to eq(success: true)
    end

    # Verifies the initial context rejection.
    it "E6 rejects an unsupported base Team context" do
      expect(Team.new.can_participant_join_team?(nil)).to eq(
        success: false, error: 'Team must belong to Assignment or Course'
      )
    end

    # Documents the unguarded participant user_id access.
    it "E7-nil raises for nil participant input in a valid scope" do
      team = make_team
      expect { team.can_participant_join_team?(nil) }.to raise_error(NoMethodError)
    end

    # Verifies inherited eligibility classification for MentoredTeam.
    it "E8 uses assignment registration and team scope for mentored teams" do
      team = make_team(:mentored)
      participant = make_participant(parent: team.assignment)
      expect(team.can_participant_join_team?(participant)).to eq(success: true)
      sibling = make_team(parent: team.assignment)
      link_member(sibling, participant)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this assignment'
      )
    end
  end

  describe "topic release through after_update" do
    # Verifies the callback exits for a populated team.
    it "T1 preserves signups when an updated team still has members" do
      team = make_team
      make_member(team)
      topic = make_topic(team.assignment)
      signup = sign_up(team, topic)
      team.update!(name: unique_name('renamed'))
      expect(signup.reload.team_id).to eq(team.id)
      expect(team.project_topics).to contain_exactly(topic)
    end

    # Verifies iteration over multiple topic associations.
    it "T2 releases all topic signups when an empty team is updated" do
      team = make_team
      topics = 2.times.map { make_topic(team.assignment) }
      signups = topics.map { |topic| sign_up(team, topic) }
      team.update!(name: unique_name('renamed'))
      expect(SignedUpTeam.where(id: signups.map(&:id))).to be_empty
      expect(ProjectTopic.where(id: topics.map(&:id)).count).to eq(2)
      expect(team.reload.project_topics).to be_empty
    end

    # Verifies the empty-topic collection requires no release.
    it "T3 updates an empty team without topics" do
      team = make_team
      new_name = unique_name('renamed')
      team.update!(name: new_name)
      expect(team.reload.name).to eq(new_name)
      expect(team.signed_up_teams).to be_empty
    end

    # Verifies promotion and cleanup through the real topic dependency.
    it "T4 promotes the earliest waiter when an empty confirmed team releases a topic" do
      team = make_team
      topic = make_topic(team.assignment)
      sign_up(team, topic)
      first_team = make_team(parent: team.assignment)
      second_team = make_team(parent: team.assignment)
      first = sign_up(first_team, topic, waitlisted: true, created_at: Time.utc(2020, 1, 1))
      second = sign_up(second_team, topic, waitlisted: true, created_at: Time.utc(2020, 1, 2))
      other_topic = make_topic(team.assignment)
      other_waitlist = sign_up(first_team, other_topic, waitlisted: true)
      team.update!(name: unique_name('renamed'))
      expect(SignedUpTeam.exists?(team_id: team.id, project_topic_id: topic.id)).to be(false)
      expect(first.reload.is_waitlisted).to be(false)
      expect(second.reload.is_waitlisted).to be(true)
      expect(SignedUpTeam.exists?(other_waitlist.id)).to be(false)
    end

    # Verifies the waitlisted release branch.
    it "T5 does not promote another waiter when releasing a waitlisted signup" do
      team = make_team
      topic = make_topic(team.assignment)
      signup = sign_up(team, topic, waitlisted: true)
      other_team = make_team(parent: team.assignment)
      other = sign_up(other_team, topic, waitlisted: true)
      team.update!(name: unique_name('renamed'))
      expect(SignedUpTeam.exists?(signup.id)).to be(false)
      expect(other.reload.is_waitlisted).to be(true)
    end

    # Verifies the callback does not swallow dependency errors.
    it "T6 propagates a topic release failure from the update" do
      team = make_team
      old_name = team.name
      topic = make_topic(team.assignment)
      sign_up(team, topic)
      # Fix the association instance so the injected failure reaches the callback.
      allow(team).to receive(:project_topics).and_return([topic])
      allow(topic).to receive(:drop_team).with(team).and_raise(StandardError, 'topic release failed')
      expect { team.update!(name: unique_name('renamed')) }.to raise_error(StandardError, 'topic release failed')
      expect(team.reload.name).to eq(old_name)
      expect(SignedUpTeam.exists?(team_id: team.id, project_topic_id: topic.id)).to be(true)
    end
  end

  describe "current behavior requiring review", :characterization do
    # Documents the missing Course max_team_size implementation.
    it "Q1 raises when reading the undefined course capacity" do
      team = make_team(:course)
      expect { team.max_size }.to raise_error(NoMethodError) { |error|
        expect(error.name).to eq(:max_team_size)
      }
    end

    # Documents the current comparison for negative limits.
    it "Q2 considers an empty team full under a negative assignment limit" do
      team = make_team(parent: make_parent(max_team_size: -1))
      expect(team.max_size).to eq(-1)
      expect(team.full?).to be(true)
    end

    # Documents nondistinct user counting.
    it "Q3 counts two participant memberships for the same user twice" do
      team = make_team
      user = make_user
      2.times do
        participant = make_participant(parent: team.assignment, user: user)
        link_member(team, participant)
      end
      expect(team.team_size).to eq(2)
      expect(team.users.distinct.count).to eq(1)
    end

    # Documents absent parent and subtype checks for direct participant input.
    it "Q4-assignment accepts a direct assignment participant from another parent" do
      team = make_team
      participant = make_participant(parent: make_parent(:assignment))
      expect(team.add_member(participant)).to eq(success: true)
      expect(team.participants).to contain_exactly(participant)
    end

    # Documents absent parent and subtype checks for direct participant input.
    it "Q4-course accepts a direct course participant from another parent" do
      team = make_team
      participant = make_participant(parent: make_parent(:course))
      expect(team.add_member(participant)).to eq(success: true)
      expect(team.participants).to contain_exactly(participant)
    end

    # Documents differing enforcement between eligibility and addition.
    it "Q5 adds a participant already on a sibling team despite failed eligibility" do
      team = make_team
      sibling = make_team(parent: team.assignment)
      participant = make_member(sibling)
      expect(team.can_participant_join_team?(participant)).to eq(
        success: false, error: 'This user is already assigned to a team for this assignment'
      )
      expect(team.add_member(participant)).to eq(success: true)
      expect(TeamsParticipant.where(participant_id: participant.id).pluck(:team_id)).to contain_exactly(team.id, sibling.id)
    end

    # Documents the delegated getter and legacy foreign-key interaction.
    it "Q6 retains a stale assignment team reference that blocks final team deletion" do
      team = make_team
      participant = make_member(team)
      participant.update!(team_id: team.id)
      expect(participant[:team_id]).to eq(team.id)
      expect { team.remove_member(participant) }.to raise_error(ActiveRecord::InvalidForeignKey)
      expect(TeamsParticipant.exists?(team_id: team.id, participant_id: participant.id)).to be(false)
      expect(Team.exists?(team.id)).to be(true)
      expect(participant.reload[:team_id]).to eq(team.id)
      expect(participant.team_id).to be_nil
    end

    # Documents the difference between dependent deletion and topic release.
    it "Q7 does not promote a waitlisted team on direct team destruction" do
      team = make_team
      topic = make_topic(team.assignment)
      signup = sign_up(team, topic)
      waiter = make_team(parent: team.assignment)
      waiting_signup = sign_up(waiter, topic, waitlisted: true)
      team.destroy!
      expect(SignedUpTeam.exists?(signup.id)).to be(false)
      expect(waiting_signup.reload.is_waitlisted).to be(true)
    end
  end

end

