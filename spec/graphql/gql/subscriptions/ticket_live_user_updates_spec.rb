# Copyright (C) 2012-2023 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Gql::Subscriptions::TicketLiveUserUpdates, :aggregate_failures, authenticated_as: :agent, type: :graphql do
  let(:agent)                         { create(:agent) }
  let(:another_agent)                 { create(:agent) }
  let(:ticket)                        { create(:ticket) }
  let(:live_user_entry)               { create(:taskbar, key: "Ticket-#{ticket.id}", user_id: agent.id, app: 'mobile', state: { editing: true }) }
  let(:live_user_entry_another_agent) { create(:taskbar, key: "Ticket-#{ticket.id}", user_id: another_agent.id, app: 'mobile', state: { editing: false }) }

  let(:mock_channel) { build_mock_channel }
  let(:variables) { { userId: Gql::ZammadSchema.id_from_object(agent), key: "Ticket-#{ticket.id}", app: 'mobile' } }
  let(:subscription) do
    <<~QUERY
      subscription ticketLiveUserUpdates($userId: ID!, $key: String!, $app: EnumTaskbarApp!) {
        ticketLiveUserUpdates(userId: $userId, key: $key, app: $app) {
          liveUsers {
            user {
              firstname
              lastname
            }
            editing
            lastInteraction
            apps
          }
        }
      }
    QUERY
  end

  before do
    live_user_entry && live_user_entry_another_agent

    gql.execute(subscription, variables: variables, context: { channel: mock_channel })
  end

  def update_taskbar_item(taskbar_item, state, agent_id)
    # Special case: By design, it is only allowed to update the taskbar of the current user.
    # We need to work around this, otherwise this test would fail.
    UserInfo.current_user_id = agent_id
    taskbar_item.update!(state: state)
    UserInfo.current_user_id = agent.id
  end

  context 'when subscribed' do
    it 'subscribes and delivers initial data' do
      expect(gql.result.data['liveUsers'].size).to eq(1)
      expect(gql.result.data['liveUsers'].first).not_to include('user' => {
                                                                  'firstname' => agent.firstname,
                                                                  'lastname'  => agent.lastname,
                                                                })

      expect(gql.result.data['liveUsers'].first).to include('user' => {
                                                              'firstname' => another_agent.firstname,
                                                              'lastname'  => another_agent.lastname,
                                                            })

      expect(gql.result.data['liveUsers'].first).to include('editing' => false)
    end

    it 'receives taskbar updates' do
      update_taskbar_item(live_user_entry_another_agent, { editing: true }, another_agent.id)

      result = mock_channel.mock_broadcasted_messages.first.dig(:result, 'data', 'ticketLiveUserUpdates', 'liveUsers')
      expect(result.size).to eq(1)

      expect(result.first).not_to include('user' => {
                                            'firstname' => agent.firstname,
                                            'lastname'  => agent.lastname,
                                          })

      expect(result.first).to include('user' => {
                                        'firstname' => another_agent.firstname,
                                        'lastname'  => another_agent.lastname,
                                      })

      expect(result.first).to include('editing' => true)
    end

    context 'with multiple viewers' do
      let(:third_agent)                 { create(:agent) }
      let(:live_user_entry_third_agent) { create(:taskbar, key: "Ticket-#{ticket.id}", user_id: third_agent.id, app: 'mobile', state: { editing: false }) }

      it 'receives taskbar updates for all viewers' do
        update_taskbar_item(live_user_entry_another_agent, { editing: true }, another_agent.id)

        result = mock_channel.mock_broadcasted_messages.last.dig(:result, 'data', 'ticketLiveUserUpdates', 'liveUsers')
        expect(result.size).to eq(1)

        UserInfo.current_user_id = third_agent.id
        live_user_entry_third_agent
        UserInfo.current_user_id = agent.id

        update_taskbar_item(live_user_entry_third_agent, { editing: true }, third_agent.id)

        result = mock_channel.mock_broadcasted_messages.last.dig(:result, 'data', 'ticketLiveUserUpdates', 'liveUsers')
        expect(result.size).to eq(2)

        expect(result.first).not_to include('user' => {
                                              'firstname' => agent.firstname,
                                              'lastname'  => agent.lastname,
                                            })

        expect(result.last).not_to include('user' => {
                                             'firstname' => agent.firstname,
                                             'lastname'  => agent.lastname,
                                           })

        expect(result.first).to include('user' => {
                                          'firstname' => another_agent.firstname,
                                          'lastname'  => another_agent.lastname,
                                        })

        expect(result.last).to include('user' => {
                                         'firstname' => third_agent.firstname,
                                         'lastname'  => third_agent.lastname,
                                       })
      end
    end
  end
end