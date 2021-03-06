# encoding: UTF-8
# frozen_string_literal: true

describe API::V2::Management::Members, type: :request do
  before do
    defaults_for_management_api_v1_security_configuration!
    management_api_v1_security_configuration.merge! \
      scopes: {
        write_members:  { permitted_signers: %i[alex jeff], mandatory_signers: %i[alex jeff] },
      }
  end

  describe 'set user group' do
    def request
      post_json '/api/v2/management/members/group', multisig_jwt_management_api_v1({ data: data }, *signers)
    end

    let(:data) { {uid: member.uid, group: 'vip-1'} }
    let(:signers) { %i[alex jeff] }
    let(:member) { create(:member, :barong) }

    it 'returns user with updated role' do
      request
      expect(response).to have_http_status(200)
      expect(JSON.parse(response.body)['group']).to eq('vip-1')
    end

    context 'invalid uid' do
      let(:data) { { uid: 'fake_uid', group: 'vip-1' }  }
      it 'returns status 404 and error' do
        request
        expect(response).to have_http_status(404)
        expect(JSON.parse(response.body)['error']).to eq("Couldn't find record.")
      end
    end

    context 'invalid record' do
      let(:data) { { uid: member.uid, group: 'vip-12222222222222222222222222222' }  }
      it 'returns status 422 and error' do
        request
        expect(response).to have_http_status(422)
        expect(JSON.parse(response.body)['errors']).to eq("Validation failed: Group is too long (maximum is 32 characters)")
      end
    end
  end
end
