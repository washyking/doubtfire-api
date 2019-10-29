require 'grape'

module Api
  class TutorialEnrolmentsApi < Grape::API
    helpers AuthenticationHelpers
    helpers AuthorisationHelpers

    before do
      authenticated?
    end

    desc 'Enrol project in a tutorial'
    post '/units/:unit_id/tutorials/:tutorial_abbr/enrolments/:project_id' do
      unit = Unit.find(params[:unit_id])
      unless authorise? current_user, unit, :enrol_student
        error!({ error: 'Not authorised to enrol student' }, 403)
      end

      tutorial = unit.tutorials.find_by(abbreviation: params[:tutorial_abbr])
      error!({ error: "No tutorial with abbreviation #{params[:tutorial_abbr]} exists for the unit" }, 403) unless tutorial.present?

      project = Project.find(params[:project_id])
      result = project.enrol_in(tutorial)

      if result.nil?
        error!({ error: 'No enrolment added' }, 403)
      else
        result
      end
    end

    desc 'Delete an enrolment in the tutorial'
    delete '/tutorials/:tutorial_id/enrolments/:id' do
      tutorial = Tutorial.find(params[:tutorial_id])
      unless authorise? current_user, tutorial.unit, :enrol_student
        error!({ error: 'Not authorised to delete tutorial enrolments' }, 403)
      end

      tutorial.tutorial_enrolments.find(params[:id]).destroy
    end
  end
end