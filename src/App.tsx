import { BrowserRouter, Navigate, Route, Routes, useParams } from 'react-router-dom'
import { AuthProvider } from './context/AuthContext'
import { ProtectedRoute } from './components/ProtectedRoute'
import { AppShell } from './components/AppShell'
import { LoginPage } from './pages/LoginPage'
import { Dashboard, NotFound, SurveyList } from './pages/Pages'
import { PrintReportPage } from './pages/PrintReportPage'
import { RecordsPage } from './pages/RecordsPage'
import { SurveyEditor } from './pages/SurveyEditor'
import { SurveyRunPage } from './pages/SurveyRunPage'

export default function App() {
  return <BrowserRouter><AuthProvider><Routes>
    <Route path="/login" element={<LoginPage />} />
    <Route element={<ProtectedRoute />}><Route element={<AppShell />}>
      <Route index element={<Dashboard />} /><Route path="/admin/new" element={<SurveyEditor />} />
      <Route path="/surveys" element={<SurveyList />} /><Route path="/surveys/:surveyId/edit" element={<SurveyEditor />} /><Route path="/surveys/run" element={<SurveyRunPage />} /><Route path="/surveys/run/:surveyId/:roundId" element={<SurveyRunPage />} /><Route path="/surveys/run/:surveyId/:roundId/:clientId" element={<SurveyRunPage />} />
      <Route path="/records" element={<RecordsPage />} /><Route path="/records/:surveyId" element={<RecordsPage />} />
      <Route path="/surveys/completion" element={<Navigate replace to="/records?tab=completion" />} /><Route path="/surveys/:surveyId/completion" element={<LegacyRecordRedirect tab="completion" />} /><Route path="/surveys/search" element={<Navigate replace to="/records" />} />
      <Route path="/reports" element={<Navigate replace to="/records?tab=analysis" />} /><Route path="/reports/:surveyId" element={<LegacyRecordRedirect tab="analysis" />} /><Route path="/reports/print" element={<PrintReportPage />} /><Route path="/reports/:surveyId/print" element={<PrintReportPage />} />
      <Route path="*" element={<NotFound />} />
    </Route></Route>
  </Routes></AuthProvider></BrowserRouter>
}

function LegacyRecordRedirect({tab}:{tab:'completion'|'analysis'}){const {surveyId}=useParams();return <Navigate replace to={`/records/${surveyId}?tab=${tab}`}/>}
