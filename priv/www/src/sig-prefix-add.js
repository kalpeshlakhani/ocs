/**
 * Copyright 2016 - 2021 SigScale Global Inc.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *      http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { PolymerElement, html } from '@polymer/polymer/polymer-element.js';
import '@polymer/iron-ajax/iron-ajax.js';
import '@polymer/paper-dialog/paper-dialog.js';
import '@polymer/app-layout/app-toolbar/app-toolbar.js';
import '@polymer/paper-progress/paper-progress.js';
import '@polymer/paper-input/paper-input.js';
import '@polymer/paper-button/paper-button.js';
import '@polymer/paper-tooltip/paper-tooltip.js';
import './style-element.js';

class prefixAdd extends PolymerElement {
	static get template() {
		return html`
			<style include="style-element"></style>
			<paper-dialog class="dialog" id="addPrefixModal" modal>
				<app-toolbar>
					<h2>Add Prefix</h2>
				</app-toolbar>
				<paper-progress
						id="progressId"
						indeterminate
						class="slow red"
						disabled="{{!loading}}">
				</paper-progress>
				<paper-input
						id="addPrefix"
						name="Prefix"
						allowed-pattern="[0-9]"
						label="Prefix"
						value="{{addPre}}">
				</paper-input>
				<paper-tooltip
						for="addPrefix"
						offset="0">
					Prefix number
				</paper-tooltip>
				<paper-input
						id="addDesc"
						name="Description"
						label="Description"
						value="{{addPreDesc}}">
				</paper-input>
				<paper-tooltip
						for="addDesc"
						offset="0">
					Prefix description
				</paper-tooltip>
				<paper-input
						id="addRateRow"
						type="number"
						name="PriceName"
						label="Rate"
						value="{{addPreRate}}">
				</paper-input>
				<paper-tooltip
						for="addRateRow"
						offset="0">
					Prefix rate
				</paper-tooltip>
				<div class="buttons">
					<paper-button dialog-confirm
							raised
							on-tap="_tableRow"
							class="submit-button">
						Submit
					</paper-button>
					<paper-button
							class="cancel-button"
							on-tap="_cancel"
							dialog-dismiss>
						Cancel
					</paper-button>
				</div>
			</paper-dialog>
			<iron-ajax
					id="addTableRowAjax"
					url="/catalogManagement/v2/pla"
					method = "POST"
					content-type="application/json"
					on-loading-changed="_onLoadingChanged"
					on-response="_addTableResponse"
					on-error="_addTableError">
			</iron-ajax>
		`;
	}
	static get properties() {
		return {
				loading: {
				type: Boolean,
				value: false
			},
			addPre: {
				type: String,
			},
			addPreDesc: {
				type: String,
			},
			addPreRate: {
				type: String,
			}
		}
	}

	_tableRow(event) {
//		var table = document.getElementById('prefixList').table;
		var table = document.body.querySelector('sig-app').shadowRoot.getElementById('prefixList').table;
		var rowName = new Object();
		rowName.id = this.addPre;
		rowName.href = "/resourceInventoryManagement/v1/logicalResource/" + table + "/" + rowName.id;
		var resource = new Array();
		var resPre = new Object();
		resPre.name = "prefix";
		var seqNum = 1;
		var value = this.addPre;
		resPre.value = {seqNum, value};
		resource.push(resPre);
		var resDes = new Object();
		resDes.name = "description";
		var seqNum = 2;
		var value = this.addPreDesc;
		resDes.value = {seqNum, value};
		resource.push(resDes);
		var resRate = new Object();
		resRate.name = "rate";
		var seqNum = 3;
		var value = this.addPreRate;
		resRate.value = {seqNum, value};
		resource.push(resRate);
		rowName.resourceCharacteristic = resource;
		var ajax = this.$.addTableRowAjax;
		ajax.url = "/resourceInventoryManagement/v1/logicalResource/" + table
		ajax.body = rowName;
		ajax.generateRequest();
		this.addPre = null;
		this.addPreDesc = null;
		this.$.addRateRow.value = null;
	}

	_addTableResponse(event) {
		this.$.addPrefixModal.close();
		document.body.querySelector('sig-app').shadowRoot.getElementById('prefixList').shadowRoot.getElementById('prefixGrid').clearCache();
		var toast = document.body.querySelector('sig-app').shadowRoot.getElementById('restError');
		toast.text = "Success";
		toast.open();
	}

	_addTableError(event) {
		var toast = document.body.querySelector('sig-app').shadowRoot.getElementById('restError');
		toast.text = "Error";
		toast.open();
	}

	_cancel() {
		this.addPre = null;
		this.addDesc = null;
		this.addRateRow = null;
	}

	_onLoadingChanged(event) {
		if (this.$.addTableRowAjax.loading) {
			this.$.progressId.disabled = false;
		} else {
			this.$.progressId.disabled = true;
		}
	}
}

window.customElements.define('sig-prefix-add', prefixAdd);
